pub const TSLanguage = opaque {};
pub const TSParser = opaque {};
pub const TSTree = opaque {};

pub const TSNode = extern struct {
    context: [4]u32,
    id: ?*const anyopaque,
    tree: ?*const TSTree,
};

pub extern fn tree_sitter_yaml() *const TSLanguage;

pub extern fn ts_parser_new() ?*TSParser;
pub extern fn ts_parser_delete(self: *TSParser) void;
pub extern fn ts_parser_set_language(self: *TSParser, language: *const TSLanguage) bool;
pub extern fn ts_parser_parse_string(
    self: *TSParser,
    old_tree: ?*const TSTree,
    string: [*]const u8,
    length: u32,
) ?*TSTree;

pub extern fn ts_tree_delete(self: *TSTree) void;
pub extern fn ts_tree_root_node(self: *const TSTree) TSNode;

pub extern fn ts_node_type(self: TSNode) [*:0]const u8;
pub extern fn ts_node_start_byte(self: TSNode) u32;
pub extern fn ts_node_end_byte(self: TSNode) u32;
pub extern fn ts_node_is_null(self: TSNode) bool;
pub extern fn ts_node_is_missing(self: TSNode) bool;
pub extern fn ts_node_has_error(self: TSNode) bool;
pub extern fn ts_node_is_error(self: TSNode) bool;
pub extern fn ts_node_child(self: TSNode, child_index: u32) TSNode;
pub extern fn ts_node_child_count(self: TSNode) u32;
pub extern fn ts_node_named_child(self: TSNode, child_index: u32) TSNode;
pub extern fn ts_node_named_child_count(self: TSNode) u32;
pub extern fn ts_node_child_by_field_name(self: TSNode, name: [*]const u8, name_length: u32) TSNode;
