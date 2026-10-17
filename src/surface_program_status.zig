//! Program status records (OSC 7501) for one core surface.
//!
//! Specification: https://www.superlogical.com/rex/docs/build/program-status
//!
//! The OSC parser (`terminal/osc/parsers/program_status.zig`) validates
//! one report at a time and leaves keeping records to its consumer. This
//! file is that consumer for the full app:
//!
//! - `Report` copies a parsed report out of the parser's buffer on the
//!   termio thread so it can travel through the surface mailbox.
//! - `Records` is owned by the surface (app thread) and applies the
//!   specification's record rules: one record per id, each report replaces
//!   its record completely, `clear` removes a record and its descendants,
//!   at most `Records.max` records with least-recently-updated eviction,
//!   and lifetime rules tied to prompts, process exit, and user input.
//! - `Records.snapshot` produces the apprt view with `app` inherited from
//!   the nearest ancestor, as the specification requires.
const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("apprt.zig");
const terminal = @import("terminal/main.zig");

const osc_status = terminal.osc.program_status;
const ParsedReport = terminal.osc.Command.ProgramStatus.Report;
const ProgramStatus = apprt.action.ProgramStatus;

/// A fixed-capacity, always NUL-terminated string.
fn Text(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        buf: [capacity:0]u8 = @splat(0),
        len: usize = 0,

        pub fn slice(self: *const Self) [:0]const u8 {
            return self.buf[0..self.len :0];
        }

        /// Copy `value`, which the parser already limited to `capacity`.
        fn set(self: *Self, value: []const u8) void {
            std.debug.assert(value.len <= capacity);
            @memcpy(self.buf[0..value.len], value);
            self.buf[value.len] = 0;
            self.len = value.len;
        }
    };
}

/// One report, owned and independent of the parser buffer. Allocated on
/// the termio thread and owned by `Records` once applied.
pub const Report = struct {
    /// What the report does. `clear` removes records instead of setting one.
    op: Op,
    kind: ProgramStatus.Kind = .none,
    progress: ?u8 = null,
    id: Text(osc_status.max_id_bytes) = .{},
    app: Text(osc_status.max_app_bytes) = .{},
    title: Text(osc_status.max_title_bytes) = .{},
    msg: Text(osc_status.max_msg_bytes) = .{},

    pub const Op = union(enum) {
        set: ProgramStatus.State,
        clear,
    };

    /// Copy a parsed report. The caller owns the result and frees it
    /// with `alloc.destroy`.
    pub fn create(alloc: Allocator, parsed: ParsedReport) Allocator.Error!*Report {
        const self = try alloc.create(Report);
        errdefer alloc.destroy(self);
        self.* = .{ .op = switch (parsed.state) {
            .idle => .{ .set = .idle },
            .working => .{ .set = .working },
            .done => .{ .set = .done },
            .blocked => .{ .set = .blocked },
            .@"error" => .{ .set = .@"error" },
            .clear => .clear,
        } };

        // `readOption` already ignores `kind` and `progress` for states
        // that don't carry them.
        if (parsed.readOption(.kind)) |k| self.kind = switch (k) {
            .permission => .permission,
            .question => .question,
            .auth => .auth,
        };
        self.progress = parsed.readOption(.progress);
        if (parsed.readOption(.id)) |v| self.id.set(v);
        if (parsed.readOption(.app)) |v| self.app.set(v);
        writeText(.title, parsed, &self.title);
        writeText(.msg, parsed, &self.msg);
        return self;
    }

    fn writeText(
        comptime option: osc_status.Option,
        parsed: ParsedReport,
        dst: anytype,
    ) void {
        var writer: std.Io.Writer = .fixed(dst.buf[0..dst.buf.len]);
        // The parser guarantees decoded text fits within the limits, which
        // are the capacities of our buffers, so this can't fail.
        parsed.writeText(option, &writer) catch unreachable;

        // Decoded in place, so only terminate it.
        dst.len = writer.end;
        dst.buf[dst.len] = 0;
    }

    fn state(self: *const Report) ProgramStatus.State {
        return switch (self.op) {
            .set => |s| s,
            // Never stored.
            .clear => unreachable,
        };
    }
};

/// The records of one surface. Not thread safe; owned by the surface on
/// the app thread.
pub const Records = struct {
    /// Ordered from least to most recently updated, for eviction.
    list: std.ArrayList(*Report) = .empty,

    /// The specification allows at most 256 and requires at least 64.
    pub const max = 256;

    pub fn deinit(self: *Records, alloc: Allocator) void {
        for (self.list.items) |r| alloc.destroy(r);
        self.list.deinit(alloc);
    }

    pub fn isEmpty(self: *const Records) bool {
        return self.list.items.len == 0;
    }

    /// Apply a report, taking ownership of it. Returns true if the records
    /// changed.
    pub fn apply(self: *Records, alloc: Allocator, report: *Report) bool {
        switch (report.op) {
            .clear => {
                defer alloc.destroy(report);
                return self.clearSubtree(alloc, report.id.slice());
            },
            .set => {},
        }

        // Reserve first so an allocation failure leaves records untouched.
        self.list.ensureUnusedCapacity(alloc, 1) catch {
            std.log.scoped(.program_status).warn(
                "out of memory storing program status record",
                .{},
            );
            alloc.destroy(report);
            return false;
        };

        // Each report replaces its record completely. Re-appending moves
        // the record to the most recently updated end.
        if (self.indexOf(report.id.slice())) |i| {
            alloc.destroy(self.list.orderedRemove(i));
        } else if (self.list.items.len >= max) {
            alloc.destroy(self.list.orderedRemove(0));
        }

        self.list.appendAssumeCapacity(report);
        return true;
    }

    /// Remove every record. Used for a full reset (RIS).
    pub fn clearAll(self: *Records, alloc: Allocator) bool {
        if (self.isEmpty()) return false;
        for (self.list.items) |r| alloc.destroy(r);
        self.list.clearRetainingCapacity();
        return true;
    }

    /// A new shell prompt started, or the process attached to the terminal
    /// exited. The specification requires dropping `working` and `blocked`
    /// and allows dropping `idle`; the program that reported them is gone.
    /// `done` and `error` survive so the user can still find them.
    pub fn pruneTransient(self: *Records, alloc: Allocator) bool {
        return self.removeIf(alloc, {}, struct {
            fn f(_: void, r: *const Report) bool {
                return switch (r.state()) {
                    .idle, .working, .blocked => true,
                    .done, .@"error" => false,
                };
            }
        }.f);
    }

    /// The user returned to the terminal and pressed a key, so they've seen
    /// the result of any `done` or `error` record.
    pub fn dismissFinished(self: *Records, alloc: Allocator) bool {
        return self.removeIf(alloc, {}, struct {
            fn f(_: void, r: *const Report) bool {
                return switch (r.state()) {
                    .done, .@"error" => true,
                    .idle, .working, .blocked => false,
                };
            }
        }.f);
    }

    /// Fill `buf` with the apprt view of the records, most recently updated
    /// last. The result points into the records and is only valid until
    /// they change.
    pub fn snapshot(
        self: *const Records,
        buf: *[max]ProgramStatus.Record,
    ) []const ProgramStatus.Record {
        for (self.list.items, buf[0..self.list.items.len]) |r, *out| {
            out.* = .{
                .state = r.state(),
                .kind = r.kind,
                .progress = if (r.progress) |p| p else -1,
                .id = r.id.slice().ptr,
                .app = self.inheritedApp(r).ptr,
                .title = r.title.slice().ptr,
                .msg = r.msg.slice().ptr,
            };
        }
        return buf[0..self.list.items.len];
    }

    /// The record's `app`, or that of its nearest ancestor that has one.
    /// The root record (empty id) is the ancestor of every record.
    fn inheritedApp(self: *const Records, r: *const Report) [:0]const u8 {
        if (r.app.len > 0) return r.app.slice();
        var id: []const u8 = r.id.slice();
        while (id.len > 0) {
            id = if (std.mem.lastIndexOfScalar(u8, id, '/')) |i| id[0..i] else "";
            const ancestor = self.list.items[self.indexOf(id) orelse continue];
            if (ancestor.app.len > 0) return ancestor.app.slice();
        }
        return "";
    }

    fn indexOf(self: *const Records, id: []const u8) ?usize {
        for (self.list.items, 0..) |r, i| {
            if (std.mem.eql(u8, r.id.slice(), id)) return i;
        }
        return null;
    }

    /// Remove the record `id` and every record beneath it. An empty id
    /// removes every record.
    fn clearSubtree(self: *Records, alloc: Allocator, id: []const u8) bool {
        if (id.len == 0) return self.clearAll(alloc);
        return self.removeIf(alloc, id, struct {
            fn f(prefix: []const u8, r: *const Report) bool {
                const rid = r.id.slice();
                if (!std.mem.startsWith(u8, rid, prefix)) return false;
                return rid.len == prefix.len or rid[prefix.len] == '/';
            }
        }.f);
    }

    fn removeIf(
        self: *Records,
        alloc: Allocator,
        ctx: anytype,
        comptime pred: fn (@TypeOf(ctx), *const Report) bool,
    ) bool {
        var kept: usize = 0;
        for (self.list.items) |r| {
            if (pred(ctx, r)) {
                alloc.destroy(r);
            } else {
                self.list.items[kept] = r;
                kept += 1;
            }
        }
        const changed = kept != self.list.items.len;
        self.list.shrinkRetainingCapacity(kept);
        return changed;
    }
};

const testing = std.testing;

/// Parse `body` (everything after `7501;`) into an owned report.
fn testReport(alloc: Allocator, body: []const u8) !*Report {
    var p: terminal.osc.Parser = .init(alloc);
    defer p.deinit();
    p.nextSlice("7501;");
    p.nextSlice(body);
    const cmd = p.end('\x1b') orelse return error.InvalidReport;
    return try Report.create(alloc, cmd.program_status.report);
}

fn testApply(records: *Records, body: []const u8) !bool {
    return records.apply(testing.allocator, try testReport(testing.allocator, body));
}

fn testSnapshot(records: *const Records) []const ProgramStatus.Record {
    const S = struct {
        var buf: [Records.max]ProgramStatus.Record = undefined;
    };
    return records.snapshot(&S.buf);
}

test "report copies every value" {
    const alloc = testing.allocator;
    // msg = "Apply?", title = "Plan"
    const r = try testReport(alloc, "state=blocked:kind=permission:progress=40:id=tf/plan:app=terraform:title=UGxhbg:msg=QXBwbHk/");
    defer alloc.destroy(r);

    try testing.expectEqual(Report.Op{ .set = .blocked }, r.op);
    try testing.expectEqual(ProgramStatus.Kind.permission, r.kind);
    try testing.expectEqual(@as(?u8, 40), r.progress);
    try testing.expectEqualStrings("tf/plan", r.id.slice());
    try testing.expectEqualStrings("terraform", r.app.slice());
    try testing.expectEqualStrings("Plan", r.title.slice());
    try testing.expectEqualStrings("Apply?", r.msg.slice());
}

test "report replaces its record completely" {
    var records: Records = .{};
    defer records.deinit(testing.allocator);

    try testing.expect(try testApply(&records, "state=working:app=cargo:progress=10"));
    try testing.expect(try testApply(&records, "state=done"));

    const snap = testSnapshot(&records);
    try testing.expectEqual(@as(usize, 1), snap.len);
    try testing.expectEqual(ProgramStatus.State.done, snap[0].state);
    try testing.expectEqual(@as(i16, -1), snap[0].progress);
    try testing.expectEqualStrings("", std.mem.span(snap[0].app));
}

test "clear removes a record and its descendants" {
    var records: Records = .{};
    defer records.deinit(testing.allocator);

    _ = try testApply(&records, "state=working");
    _ = try testApply(&records, "state=working:id=deploy");
    _ = try testApply(&records, "state=working:id=deploy/us");
    _ = try testApply(&records, "state=working:id=deployer");

    try testing.expect(try testApply(&records, "state=clear:id=deploy"));
    const snap = testSnapshot(&records);
    try testing.expectEqual(@as(usize, 2), snap.len);
    try testing.expectEqualStrings("", std.mem.span(snap[0].id));
    try testing.expectEqualStrings("deployer", std.mem.span(snap[1].id));

    // Clearing something that doesn't exist changes nothing.
    try testing.expect(!try testApply(&records, "state=clear:id=nope"));

    // No id clears everything.
    try testing.expect(try testApply(&records, "state=clear"));
    try testing.expect(records.isEmpty());
}

test "app is inherited from the nearest ancestor" {
    var records: Records = .{};
    defer records.deinit(testing.allocator);

    _ = try testApply(&records, "state=working:app=deploy");
    _ = try testApply(&records, "state=working:id=a:app=sub");
    _ = try testApply(&records, "state=working:id=a/b/c");
    _ = try testApply(&records, "state=working:id=x/y");

    const snap = testSnapshot(&records);
    try testing.expectEqualStrings("sub", std.mem.span(snap[2].app));
    try testing.expectEqualStrings("deploy", std.mem.span(snap[3].app));
}

test "lifetime rules" {
    var records: Records = .{};
    defer records.deinit(testing.allocator);
    const alloc = testing.allocator;

    _ = try testApply(&records, "state=idle:id=a");
    _ = try testApply(&records, "state=working:id=b");
    _ = try testApply(&records, "state=blocked:id=c");
    _ = try testApply(&records, "state=done:id=d");
    _ = try testApply(&records, "state=error:id=e");

    // Prompt or process exit drops everything but done and error.
    try testing.expect(records.pruneTransient(alloc));
    try testing.expect(!records.pruneTransient(alloc));
    try testing.expectEqual(@as(usize, 2), records.list.items.len);

    // A key press dismisses done and error.
    try testing.expect(records.dismissFinished(alloc));
    try testing.expect(records.isEmpty());
    try testing.expect(!records.dismissFinished(alloc));
}

test "least recently updated record is evicted at the cap" {
    var records: Records = .{};
    defer records.deinit(testing.allocator);

    var buf: [32]u8 = undefined;
    for (0..Records.max) |i| {
        _ = try testApply(&records, try std.fmt.bufPrint(&buf, "state=idle:id=r{d}", .{i}));
    }

    // Touch r0 so r1 becomes the least recently updated.
    _ = try testApply(&records, "state=working:id=r0");
    _ = try testApply(&records, "state=idle:id=new");

    try testing.expectEqual(@as(usize, Records.max), records.list.items.len);
    try testing.expect(records.indexOf("r1") == null);
    try testing.expect(records.indexOf("r0") != null);
    try testing.expect(records.indexOf("new") != null);
}
