#!/usr/bin/python
"""A deliberately tiny module for the navigation fixture."""
from ansible.module_utils.basic import AnsibleModule


def main():
    module = AnsibleModule(argument_spec={"label": {"type": "str", "required": True}})
    module.exit_json(changed=False)


if __name__ == "__main__":
    main()
