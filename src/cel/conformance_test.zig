const std = @import("std");
const ast = @import("../ast/root.zig");
const registry = @import("registry.zig");
const evaluator = @import("evaluator.zig");
const builtins = @import("builtins.zig");

const Case = struct {
    rule_id: []const u8,
    path: []const u8 = "/ws/site.yml",
    bad: []const u8,
    good: []const u8,
    bad_options: []const registry.RuleOptionOverride = &.{},
    good_options: []const registry.RuleOptionOverride = &.{},
};

fn evalCodes(
    alloc: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    rule_options: []const registry.RuleOptionOverride,
) !struct { codes: []const []const u8, runtime_error_count: usize } {
    var doc = try ast.build(alloc, path, std.fs.path.basename(path), source);
    defer doc.deinit();

    var rs = try registry.buildRuleSet(alloc, 1, .{
        .include_builtins = true,
        .rule_options = rule_options,
    });
    defer rs.deinit();
    try std.testing.expectEqual(@as(usize, 0), rs.errors.len);

    var wrs = try rs.cloneForWorker(alloc);
    defer wrs.deinit();

    const res = try evaluator.evaluateDocument(alloc, &doc, &wrs, .{}, .{}, .utf16, null);
    for (res.runtime_errors) |re| {
        std.debug.print("RUNTIME ERROR in rule '{s}': {s}\n", .{ re.rule_id, re.message });
    }
    var codes = std.ArrayList([]const u8).empty;
    for (res.diagnostics) |d| {
        if (d.code) |c| try codes.append(alloc, c);
    }
    return .{
        .codes = try codes.toOwnedSlice(alloc),
        .runtime_error_count = res.runtime_errors.len,
    };
}

fn containsCode(codes: []const []const u8, expected: []const u8) bool {
    for (codes) |c| {
        if (std.mem.eql(u8, c, expected)) return true;
    }
    return false;
}

test "all 69 builtin rules load without errors and have unique ids" {
    try std.testing.expectEqual(@as(usize, 69), builtins.all.len);
    var rs = try registry.buildRuleSet(std.testing.allocator, 1, .{ .include_builtins = true });
    defer rs.deinit();
    try std.testing.expectEqual(@as(usize, 0), rs.errors.len);
    try std.testing.expectEqual(builtins.all.len, rs.rules.len);
}

test "rule conformance matrix positive and negative fixtures for every approved builtin" {
    const cases = [_]Case{
        .{
            .rule_id = "zals/parse-issue",
            .bad = "- hosts: all\n  tasks:\n    - name: missing action\n",
            .good = "- name: ok\n  hosts: all\n  tasks:\n    - name: ping\n      ansible.builtin.ping:\n",
        },
        .{
            .rule_id = "argument-specs[missing]",
            .path = "/ws/roles/demo/meta/argument_specs.yml",
            .bad = "other_key: 1\n",
            .good = "argument_specs:\n  main:\n    options:\n      port:\n        type: int\n",
        },
        .{
            .rule_id = "argument-specs[entry-not-mapping]",
            .path = "/ws/roles/demo/meta/argument_specs.yml",
            .bad = "argument_specs:\n  main: just a string\n",
            .good = "argument_specs:\n  main:\n    options:\n      port:\n        type: int\n",
        },
        .{
            .rule_id = "argument-specs[option-not-mapping]",
            .path = "/ws/roles/demo/meta/argument_specs.yml",
            .bad = "argument_specs:\n  main:\n    options:\n      port: oops\n",
            .good = "argument_specs:\n  main:\n    options:\n      port:\n        type: int\n",
        },
        .{
            .rule_id = "argument-specs[unknown-entry-keys]",
            .path = "/ws/roles/demo/meta/argument_specs.yml",
            .bad = "argument_specs:\n  main:\n    short_description: Demo\n    unknown_key: oops\n    options: {}\n",
            .good = "argument_specs:\n  main:\n    short_description: Demo\n    description: Valid.\n    author: Jane Doe\n    options: {}\n",
        },
        .{
            .rule_id = "argument-specs[unknown-option-keys]",
            .path = "/ws/roles/demo/meta/argument_specs.yml",
            .bad = "argument_specs:\n  main:\n    options:\n      conf:\n        type: dict\n        options:\n          mode:\n            tpyo_key: oops\n",
            .good = "argument_specs:\n  main:\n    options:\n      conf:\n        type: dict\n        options:\n          mode:\n            type: str\n            choices: [a, b]\n",
        },
        .{
            .rule_id = "argument-specs[default-and-required]",
            .path = "/ws/roles/demo/meta/argument_specs.yml",
            .bad = "argument_specs:\n  main:\n    options:\n      conflict:\n        type: str\n        default: present\n        required: true\n",
            .good = "argument_specs:\n  main:\n    options:\n      ok:\n        type: str\n        default: present\n        required: false\n",
        },
        .{
            .rule_id = "argument-specs[secret-no-log]",
            .path = "/ws/roles/demo/meta/argument_specs.yml",
            .bad = "argument_specs:\n  main:\n    options:\n      demo_password:\n        type: str\n",
            .good = "argument_specs:\n  main:\n    options:\n      demo_password:\n        type: str\n        no_log: true\n",
        },
        .{
            .rule_id = "argument-specs[markup-fqcn]",
            .path = "/ws/roles/demo/meta/argument_specs.yml",
            .bad = "argument_specs:\n  main:\n    description: Broken M(copy) reference.\n    options: {}\n",
            .good = "argument_specs:\n  main:\n    description: Uses M(ansible.builtin.copy) and C(code).\n    options: {}\n",
        },
        .{
            .rule_id = "avoid-implicit",
            .bad = "- name: p\n  hosts: all\n  tasks:\n    - name: bad copy\n      ansible.builtin.copy:\n        dest: /tmp/a\n        mode: '0644'\n        content: 123\n",
            .good = "- name: p\n  hosts: all\n  tasks:\n    - name: good copy\n      ansible.builtin.copy:\n        dest: /tmp/a\n        mode: '0644'\n        content: '123'\n",
        },
        .{
            .rule_id = "command-instead-of-module",
            .bad = "- name: p\n  hosts: all\n  tasks:\n    - name: clone\n      ansible.builtin.command: git clone https://example.com/a.git\n      changed_when: false\n",
            .good = "- name: p\n  hosts: all\n  tasks:\n    - name: status\n      ansible.builtin.command: git status\n      changed_when: false\n",
        },
        .{
            .rule_id = "command-instead-of-shell",
            .bad = "- name: p\n  hosts: all\n  tasks:\n    - name: plain echo\n      ansible.builtin.shell: echo hello\n      changed_when: false\n",
            .good = "- name: p\n  hosts: all\n  tasks:\n    - name: redirected\n      ansible.builtin.shell: echo hello > /tmp/out\n      changed_when: false\n",
        },
        .{
            .rule_id = "complexity[play]",
            .bad = "- name: p1\n  hosts: all\n- name: p2\n  hosts: all\n",
            .good = "- name: p1\n  hosts: all\n",
            .bad_options = &.{.{
                .rule_id = "complexity",
                .entries = &.{.{ .key = "max_plays", .value = .{ .int_v = 1 } }},
            }},
            .good_options = &.{.{
                .rule_id = "complexity",
                .entries = &.{.{ .key = "max_plays", .value = .{ .int_v = 1 } }},
            }},
        },
        .{
            .rule_id = "complexity[tasks]",
            .bad = "- name: p\n  hosts: all\n  tasks:\n    - name: t1\n      ansible.builtin.ping:\n    - name: t2\n      ansible.builtin.ping:\n",
            .good = "- name: p\n  hosts: all\n  tasks:\n    - name: t1\n      ansible.builtin.ping:\n",
            .bad_options = &.{.{
                .rule_id = "complexity",
                .entries = &.{.{ .key = "max_tasks", .value = .{ .int_v = 1 } }},
            }},
            .good_options = &.{.{
                .rule_id = "complexity",
                .entries = &.{.{ .key = "max_tasks", .value = .{ .int_v = 1 } }},
            }},
        },
        .{
            .rule_id = "complexity[nesting]",
            .bad = "- name: p\n  hosts: all\n  tasks:\n    - block:\n        - block:\n            - block:\n                - name: deep\n                  ansible.builtin.ping:\n",
            .good = "- name: p\n  hosts: all\n  tasks:\n    - block:\n        - name: shallow\n          ansible.builtin.ping:\n",
        },
        .{
            .rule_id = "deprecated-bare-vars",
            .bad = "- name: p\n  hosts: all\n  tasks:\n    - name: loop bare\n      ansible.builtin.debug:\n        msg: '{{ item }}'\n      with_items: my_list\n",
            .good = "- name: p\n  hosts: all\n  tasks:\n    - name: loop templated\n      ansible.builtin.debug:\n        msg: '{{ item }}'\n      with_items: '{{ my_list }}'\n",
        },
        .{
            .rule_id = "deprecated-local-action",
            .bad = "- name: p\n  hosts: all\n  tasks:\n    - name: local\n      local_action: ansible.builtin.ping\n",
            .good = "- name: p\n  hosts: all\n  tasks:\n    - name: delegated\n      ansible.builtin.ping:\n      delegate_to: localhost\n",
        },
        .{
            .rule_id = "deprecated-module",
            .bad = "- name: p\n  hosts: all\n  tasks:\n    - name: old ec2\n      ec2:\n        instance_type: t2.micro\n",
            .good = "- name: p\n  hosts: all\n  tasks:\n    - name: ping\n      ansible.builtin.ping:\n",
        },
        .{
            .rule_id = "empty-string-compare",
            .bad = "- name: p\n  hosts: all\n  tasks:\n    - name: cmp\n      ansible.builtin.ping:\n      when: my_var == \"\"\n",
            .good = "- name: p\n  hosts: all\n  tasks:\n    - name: cmp\n      ansible.builtin.ping:\n      when: my_var | length == 0\n",
        },
        .{
            .rule_id = "fqcn[keyword]",
            .bad = "- import_playbook: other.yml\n",
            .good = "- ansible.builtin.import_playbook: other.yml\n",
        },
        .{
            .rule_id = "galaxy-version-incorrect",
            .path = "/ws/galaxy.yml",
            .bad = "namespace: acme\nname: demo\nversion: '0.1.0'\ntags: [linux]\nrepository: https://example.com\nlicense: [MIT]\n",
            .good = "namespace: acme\nname: demo\nversion: '1.0.0'\ntags: [linux]\nrepository: https://example.com\nlicense: [MIT]\n",
        },
        .{
            .rule_id = "galaxy[tags]",
            .path = "/ws/galaxy.yml",
            .bad = "namespace: acme\nname: demo\nversion: '1.0.0'\nrepository: https://example.com\nlicense: [MIT]\n",
            .good = "namespace: acme\nname: demo\nversion: '1.0.0'\ntags: [linux]\nrepository: https://example.com\nlicense: [MIT]\n",
        },
        .{
            .rule_id = "galaxy[tags-format]",
            .path = "/ws/galaxy.yml",
            .bad = "namespace: acme\nname: demo\nversion: '1.0.0'\ntags: [Bad-Tag]\nrepository: https://example.com\nlicense: [MIT]\n",
            .good = "namespace: acme\nname: demo\nversion: '1.0.0'\ntags: [good_tag]\nrepository: https://example.com\nlicense: [MIT]\n",
        },
        .{
            .rule_id = "galaxy[tags-length]",
            .path = "/ws/galaxy.yml",
            .bad = "namespace: acme\nname: demo\nversion: '1.0.0'\ntags: [a]\nrepository: https://example.com\nlicense: [MIT]\n",
            .good = "namespace: acme\nname: demo\nversion: '1.0.0'\ntags: [ab]\nrepository: https://example.com\nlicense: [MIT]\n",
        },
        .{
            .rule_id = "galaxy[tags-count]",
            .path = "/ws/galaxy.yml",
            .bad = "namespace: acme\nname: demo\nversion: '1.0.0'\ntags: [t1, t2, t3, t4, t5, t6, t7, t8, t9, t10, t11, t12, t13, t14, t15, t16, t17, t18, t19, t20, t21]\nrepository: https://example.com\nlicense: [MIT]\n",
            .good = "namespace: acme\nname: demo\nversion: '1.0.0'\ntags: [t1, t2]\nrepository: https://example.com\nlicense: [MIT]\n",
        },
        .{
            .rule_id = "galaxy[version-missing]",
            .path = "/ws/galaxy.yml",
            .bad = "namespace: acme\nname: demo\ntags: [linux]\nrepository: https://example.com\nlicense: [MIT]\n",
            .good = "namespace: acme\nname: demo\nversion: '1.0.0'\ntags: [linux]\nrepository: https://example.com\nlicense: [MIT]\n",
        },
        .{
            .rule_id = "galaxy[invalid-dependency-version]",
            .path = "/ws/galaxy.yml",
            .bad = "namespace: acme\nname: demo\nversion: '1.0.0'\ntags: [linux]\nrepository: https://example.com\nlicense: [MIT]\ndependencies:\n  ansible.posix: '   '\n",
            .good = "namespace: acme\nname: demo\nversion: '1.0.0'\ntags: [linux]\nrepository: https://example.com\nlicense: [MIT]\ndependencies:\n  ansible.posix: '>=1.0.0'\n",
        },
        .{
            .rule_id = "galaxy[no-repository]",
            .path = "/ws/galaxy.yml",
            .bad = "namespace: acme\nname: demo\nversion: '1.0.0'\ntags: [linux]\nlicense: [MIT]\n",
            .good = "namespace: acme\nname: demo\nversion: '1.0.0'\ntags: [linux]\nrepository: https://example.com\nlicense: [MIT]\n",
        },
        .{
            .rule_id = "galaxy[no-license]",
            .path = "/ws/galaxy.yml",
            .bad = "namespace: acme\nname: demo\nversion: '1.0.0'\ntags: [linux]\nrepository: https://example.com\n",
            .good = "namespace: acme\nname: demo\nversion: '1.0.0'\ntags: [linux]\nrepository: https://example.com\nlicense_file: LICENSE\n",
        },
        .{
            .rule_id = "ignore-errors",
            .bad = "- name: p\n  hosts: all\n  tasks:\n    - name: risky\n      ansible.builtin.ping:\n      ignore_errors: true\n",
            .good = "- name: p\n  hosts: all\n  tasks:\n    - name: registered\n      ansible.builtin.ping:\n      ignore_errors: true\n      register: res\n",
        },
        .{
            .rule_id = "inline-env-var",
            .bad = "- name: p\n  hosts: all\n  tasks:\n    - name: env\n      ansible.builtin.command: FOO=1 echo hi\n      changed_when: false\n",
            .good = "- name: p\n  hosts: all\n  tasks:\n    - name: env\n      ansible.builtin.command: echo hi\n      environment:\n        FOO: '1'\n      changed_when: false\n",
        },
        .{
            .rule_id = "jinja-template-extension",
            .bad = "- name: p\n  hosts: all\n  tasks:\n    - name: tpl\n      ansible.builtin.template:\n        src: app.conf\n        dest: /etc/app.conf\n        mode: '0644'\n",
            .good = "- name: p\n  hosts: all\n  tasks:\n    - name: tpl\n      ansible.builtin.template:\n        src: app.conf.j2\n        dest: /etc/app.conf\n        mode: '0644'\n",
        },
        .{
            .rule_id = "key-order[play]",
            .bad = "- hosts: all\n  name: out of order\n  tasks: []\n",
            .good = "- name: in order\n  hosts: all\n  tasks: []\n",
        },
        .{
            .rule_id = "key-order[task]",
            .bad = "- name: p\n  hosts: all\n  tasks:\n    - ansible.builtin.ping:\n      name: late name\n",
            .good = "- name: p\n  hosts: all\n  tasks:\n    - name: early name\n      ansible.builtin.ping:\n",
        },
        .{
            .rule_id = "latest[git]",
            .bad = "- name: p\n  hosts: all\n  tasks:\n    - name: git head\n      ansible.builtin.git:\n        repo: https://example.com/r.git\n        dest: /tmp/r\n",
            .good = "- name: p\n  hosts: all\n  tasks:\n    - name: git pinned\n      ansible.builtin.git:\n        repo: https://example.com/r.git\n        dest: /tmp/r\n        version: v1.2.3\n",
        },
        .{
            .rule_id = "latest[hg]",
            .bad = "- name: p\n  hosts: all\n  tasks:\n    - name: hg tip\n      community.general.hg:\n        repo: https://example.com/r\n        dest: /tmp/r\n        revision: tip\n",
            .good = "- name: p\n  hosts: all\n  tasks:\n    - name: hg pinned\n      hg:\n        repo: https://example.com/r\n        dest: /tmp/r\n        revision: 1234abcd\n",
        },
        .{
            .rule_id = "literal-compare",
            .bad = "- name: p\n  hosts: all\n  tasks:\n    - name: lit\n      ansible.builtin.ping:\n      when: flag == true\n",
            .good = "- name: p\n  hosts: all\n  tasks:\n    - name: lit\n      ansible.builtin.ping:\n      when: flag | bool\n",
        },
        .{
            .rule_id = "meta-incorrect",
            .path = "/ws/roles/demo/meta/main.yml",
            .bad = "galaxy_info:\n  author: your name\n  description: ok\n  license: MIT\n  galaxy_tags: [web]\n",
            .good = "galaxy_info:\n  author: Alice\n  description: real role\n  license: MIT\n  galaxy_tags: [web]\n",
        },
        .{
            .rule_id = "meta-no-tags",
            .path = "/ws/roles/demo/meta/main.yml",
            .bad = "galaxy_info:\n  author: Alice\n  description: real role\n  license: MIT\n",
            .good = "galaxy_info:\n  author: Alice\n  description: real role\n  license: MIT\n  galaxy_tags: [web]\n",
        },
        .{
            .rule_id = "meta-video-links",
            .path = "/ws/roles/demo/meta/main.yml",
            .bad = "galaxy_info:\n  author: Alice\n  description: real\n  license: MIT\n  galaxy_tags: [web]\n  video_links:\n    - url: https://example.com/bad\n      title: bad\n",
            .good = "galaxy_info:\n  author: Alice\n  description: real\n  license: MIT\n  galaxy_tags: [web]\n  video_links:\n    - url: https://www.youtube.com/watch?v=abc123\n      title: demo\n",
        },
        .{
            .rule_id = "name[play]",
            .bad = "- hosts: all\n  tasks: []\n",
            .good = "- name: named play\n  hosts: all\n  tasks: []\n",
        },
        .{
            .rule_id = "name[missing]",
            .bad = "- name: p\n  hosts: all\n  tasks:\n    - ansible.builtin.ping:\n",
            .good = "- name: p\n  hosts: all\n  tasks:\n    - name: ping hosts\n      ansible.builtin.ping:\n",
        },
        .{
            .rule_id = "name[unique]",
            .bad = "- name: p\n  hosts: all\n  tasks:\n    - name: same\n      ansible.builtin.ping:\n    - name: same\n      ansible.builtin.ping:\n",
            .good = "- name: p\n  hosts: all\n  tasks:\n    - name: first\n      ansible.builtin.ping:\n    - name: second\n      ansible.builtin.ping:\n",
        },
        .{
            .rule_id = "name[template]",
            .bad = "- name: p\n  hosts: all\n  tasks:\n    - name: '{{ svc }} restart'\n      ansible.builtin.ping:\n",
            .good = "- name: p\n  hosts: all\n  tasks:\n    - name: 'Restart {{ svc }}'\n      ansible.builtin.ping:\n",
        },
        .{
            .rule_id = "no-changed-when",
            .bad = "- name: p\n  hosts: all\n  tasks:\n    - name: run\n      ansible.builtin.command: echo hi\n",
            .good = "- name: p\n  hosts: all\n  tasks:\n    - name: run\n      ansible.builtin.command: echo hi\n      changed_when: false\n",
        },
        .{
            .rule_id = "no-free-form",
            .bad = "- name: p\n  hosts: all\n  tasks:\n    - name: free form copy\n      ansible.builtin.copy: src=a dest=b mode=0644\n",
            .good = "- name: p\n  hosts: all\n  tasks:\n    - name: mapping copy\n      ansible.builtin.copy:\n        src: a\n        dest: b\n        mode: '0644'\n",
        },
        .{
            .rule_id = "no-free-form[raw]",
            .bad = "- name: p\n  hosts: all\n  tasks:\n    - name: raw kv\n      ansible.builtin.raw: echo hi executable=/bin/bash\n      changed_when: false\n",
            .good = "- name: p\n  hosts: all\n  tasks:\n    - name: raw clean\n      ansible.builtin.raw: echo hi\n      changed_when: false\n",
        },
        .{
            .rule_id = "no-free-form[raw-non-string]",
            .bad = "- name: p\n  hosts: all\n  tasks:\n    - name: raw map\n      ansible.builtin.raw:\n        cmd: echo hi\n      changed_when: false\n",
            .good = "- name: p\n  hosts: all\n  tasks:\n    - name: raw str\n      ansible.builtin.raw: echo hi\n      changed_when: false\n",
        },
        .{
            .rule_id = "no-handler",
            .bad = "- name: p\n  hosts: all\n  tasks:\n    - name: reload\n      ansible.builtin.ping:\n      when: res.changed\n",
            .good = "- name: p\n  hosts: all\n  handlers:\n    - name: reload\n      ansible.builtin.ping:\n      when: res.changed\n",
        },
        .{
            .rule_id = "no-jinja-when",
            .bad = "- name: p\n  hosts: all\n  tasks:\n    - name: templated when\n      ansible.builtin.ping:\n      when: '{{ ready }}'\n",
            .good = "- name: p\n  hosts: all\n  tasks:\n    - name: plain when\n      ansible.builtin.ping:\n      when: ready\n",
        },
        .{
            .rule_id = "no-log-password",
            .bad = "- name: p\n  hosts: all\n  tasks:\n    - name: user pass\n      ansible.builtin.user:\n        name: bob\n        password: secret\n",
            .good = "- name: p\n  hosts: all\n  tasks:\n    - name: user pass\n      ansible.builtin.user:\n        name: bob\n        password: secret\n      no_log: true\n",
        },
        .{
            .rule_id = "no-prompting",
            .bad = "- name: p\n  hosts: all\n  vars_prompt:\n    - name: pw\n",
            .good = "- name: p\n  hosts: all\n  tasks:\n    - name: timed pause\n      ansible.builtin.pause:\n        seconds: 5\n",
        },
        .{
            .rule_id = "no-relative-paths",
            .bad = "- name: p\n  hosts: all\n  tasks:\n    - name: rel copy\n      ansible.builtin.copy:\n        src: ../files/a\n        dest: /tmp/a\n        mode: '0644'\n",
            .good = "- name: p\n  hosts: all\n  tasks:\n    - name: clean copy\n      ansible.builtin.copy:\n        src: files/a\n        dest: /tmp/a\n        mode: '0644'\n",
        },
        .{
            .rule_id = "no-same-owner",
            .bad = "- name: p\n  hosts: all\n  tasks:\n    - name: sync\n      synchronize:\n        src: /a\n        dest: /b\n",
            .good = "- name: p\n  hosts: all\n  tasks:\n    - name: sync\n      synchronize:\n        src: /a\n        dest: /b\n        owner: false\n        group: false\n",
        },
        .{
            .rule_id = "no-tabs",
            .bad = "- name: p\n  hosts: all\n  tasks:\n    - name: tabbed\n      ansible.builtin.debug:\n        msg: \"a\\tb\"\n",
            .good = "- name: p\n  hosts: all\n  tasks:\n    - name: spaced\n      ansible.builtin.debug:\n        msg: \"a b\"\n",
        },
        .{
            .rule_id = "only-builtins",
            .bad = "- name: p\n  hosts: all\n  tasks:\n    - name: ufw\n      community.general.ufw:\n        state: enabled\n",
            .good = "- name: p\n  hosts: all\n  tasks:\n    - name: ufw allowed\n      community.general.ufw:\n        state: enabled\n",
            .good_options = &.{.{
                .rule_id = "only-builtins",
                .entries = &.{.{ .key = "allow_list", .value = .{ .string_list_v = &.{"community.general.ufw"} } }},
            }},
        },
        .{
            .rule_id = "package-latest",
            .bad = "- name: p\n  hosts: all\n  tasks:\n    - name: install pkg\n      ansible.builtin.apt:\n        name: curl\n        state: latest\n",
            .good = "- name: p\n  hosts: all\n  tasks:\n    - name: install pkg\n      ansible.builtin.apt:\n        name: curl\n        state: present\n",
        },
        .{
            .rule_id = "partial-become[play]",
            .bad = "- name: p\n  hosts: all\n  become_user: root\n  tasks: []\n",
            .good = "- name: p\n  hosts: all\n  become: true\n  become_user: root\n  tasks: []\n",
        },
        .{
            .rule_id = "partial-become[task]",
            .bad = "- name: p\n  hosts: all\n  tasks:\n    - name: t\n      ansible.builtin.ping:\n      become_user: root\n",
            .good = "- name: p\n  hosts: all\n  tasks:\n    - name: t\n      ansible.builtin.ping:\n      become: true\n      become_user: root\n",
        },
        .{
            .rule_id = "playbook-extension",
            .path = "/ws/site.txt",
            .bad = "- name: p\n  hosts: all\n  tasks: []\n",
            .good = "key: value\n",
        },
        .{
            .rule_id = "risky-file-permissions",
            .bad = "- name: p\n  hosts: all\n  tasks:\n    - name: copy no mode\n      ansible.builtin.copy:\n        src: a\n        dest: /tmp/a\n",
            .good = "- name: p\n  hosts: all\n  tasks:\n    - name: copy with mode\n      ansible.builtin.copy:\n        src: a\n        dest: /tmp/a\n        mode: '0644'\n",
        },
        .{
            .rule_id = "risky-shell-pipe",
            .bad = "- name: p\n  hosts: all\n  tasks:\n    - name: piped\n      ansible.builtin.shell: cat /etc/hosts | grep localhost\n      changed_when: false\n",
            .good = "- name: p\n  hosts: all\n  tasks:\n    - name: piped safe\n      ansible.builtin.shell: set -o pipefail && cat /etc/hosts | grep localhost\n      changed_when: false\n",
        },
        .{
            .rule_id = "role-name[path]",
            .bad = "- name: p\n  hosts: all\n  roles:\n    - ../roles/web\n",
            .good = "- name: p\n  hosts: all\n  roles:\n    - web\n",
        },
        .{
            .rule_id = "run-once[play]",
            .bad = "- name: p\n  hosts: all\n  strategy: free\n  run_once: true\n  tasks: []\n",
            .good = "- name: p\n  hosts: all\n  strategy: linear\n  run_once: true\n  tasks: []\n",
        },
        .{
            .rule_id = "run-once[task]",
            .bad = "- name: p\n  hosts: all\n  strategy: free\n  tasks:\n    - name: once\n      ansible.builtin.ping:\n      run_once: true\n",
            .good = "- name: p\n  hosts: all\n  strategy: linear\n  tasks:\n    - name: once\n      ansible.builtin.ping:\n      run_once: true\n",
        },
        .{
            .rule_id = "schema[moves]",
            .bad = "- name: p\n  hosts: all\n  tasks:\n    - name: old sudo\n      ansible.builtin.ping:\n      sudo: true\n",
            .good = "- name: p\n  hosts: all\n  tasks:\n    - name: become\n      ansible.builtin.ping:\n      become: true\n",
        },
        .{
            .rule_id = "var-naming[non-string]",
            .path = "/ws/vars/main.yml",
            .bad = "123: bad\n",
            .good = "good_var: ok\n",
        },
        .{
            .rule_id = "var-naming[non-ascii]",
            .path = "/ws/vars/main.yml",
            .bad = "café: bad\n",
            .good = "cafe: ok\n",
        },
        .{
            .rule_id = "var-naming[no-keyword]",
            .path = "/ws/vars/main.yml",
            .bad = "import: bad\n",
            .good = "import_name: ok\n",
        },
    };

    try std.testing.expectEqual(builtins.all.len, cases.len);

    for (cases) |c| {
        var bad_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer bad_arena.deinit();
        const bad_res = try evalCodes(bad_arena.allocator(), c.path, c.bad, c.bad_options);
        try std.testing.expectEqual(@as(usize, 0), bad_res.runtime_error_count);
        if (!containsCode(bad_res.codes, c.rule_id)) {
            std.debug.print("EXPECTED rule '{s}' to fire on bad fixture, got {d} codes\n", .{ c.rule_id, bad_res.codes.len });
            return error.TestExpectedEqual;
        }

        var good_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer good_arena.deinit();
        const good_res = try evalCodes(good_arena.allocator(), c.path, c.good, c.good_options);
        try std.testing.expectEqual(@as(usize, 0), good_res.runtime_error_count);
        if (containsCode(good_res.codes, c.rule_id)) {
            std.debug.print("EXPECTED rule '{s}' NOT to fire on good fixture\n", .{c.rule_id});
            return error.TestUnexpectedResult;
        }
    }
}
