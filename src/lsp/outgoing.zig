//! Helpers for building and queuing outgoing JSON-RPC messages.
//!
//! Production output goes through Writer so every message shares one FIFO and
//! framing owner. It copies serialized bytes before the request arena expires.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const json_util = @import("json_util.zig");
const Writer = @import("writer.zig").Writer;

pub fn sendValue(writer: *Writer, a: Allocator, value: Value) !void {
    const bytes = try std.json.Stringify.valueAlloc(a, value, .{});
    try writer.writeMessage(bytes);
}

pub fn sendResult(writer: *Writer, a: Allocator, id: Value, result: Value) !void {
    var o = json_util.obj(a);
    try o.put("jsonrpc", json_util.str("2.0"));
    try o.put("id", id);
    try o.put("result", result);
    try sendValue(writer, a, .{ .object = o });
}

pub fn sendError(writer: *Writer, a: Allocator, id: Value, code: i64, message: []const u8) !void {
    var err_obj = json_util.obj(a);
    try err_obj.put("code", json_util.num(code));
    try err_obj.put("message", json_util.str(message));
    var o = json_util.obj(a);
    try o.put("jsonrpc", json_util.str("2.0"));
    try o.put("id", id);
    try o.put("error", .{ .object = err_obj });
    try sendValue(writer, a, .{ .object = o });
}

pub fn sendNotification(writer: *Writer, a: Allocator, method: []const u8, params: Value) !void {
    var o = json_util.obj(a);
    try o.put("jsonrpc", json_util.str("2.0"));
    try o.put("method", json_util.str(method));
    try o.put("params", params);
    try sendValue(writer, a, .{ .object = o });
}

pub fn logMessage(writer: *Writer, a: Allocator, level: i64, message: []const u8) !void {
    var p = json_util.obj(a);
    try p.put("type", json_util.num(level));
    try p.put("message", json_util.str(message));
    try sendNotification(writer, a, "window/logMessage", .{ .object = p });
}

pub fn showMessage(writer: *Writer, a: Allocator, level: i64, message: []const u8) !void {
    var p = json_util.obj(a);
    try p.put("type", json_util.num(level));
    try p.put("message", json_util.str(message));
    try sendNotification(writer, a, "window/showMessage", .{ .object = p });
}

/// Send a server-to-client request. The client's response carries `id` and is
/// ignored by the dispatcher (it has no method).
pub fn sendRequest(writer: *Writer, a: Allocator, id: []const u8, method: []const u8, params: Value) !void {
    var o = json_util.obj(a);
    try o.put("jsonrpc", json_util.str("2.0"));
    try o.put("id", json_util.str(id));
    try o.put("method", json_util.str(method));
    try o.put("params", params);
    try sendValue(writer, a, .{ .object = o });
}
