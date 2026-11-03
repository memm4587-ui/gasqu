const std = @import("std");

pub fn getNameVers(get: std.mem.Allocator) ![]u8 {
    const cwd = std.fs.cwd();
    const max_size = 1024;

    const file_contents = try cwd.readFileAlloc(get, "/proc/version", max_size);

    return file_contents;
}

pub fn readCpuCores() !u8 {
    const cwd = std.fs.cwd();
    var buf: [16384]u8 = undefined;

    const readbuf = try cwd.readFile("/proc/cpuinfo", &buf);

    const cect = std.mem.count(u8, readbuf, "processor");

    return @intCast(cect);
}

const mem = struct {
    total: u64,
    avail: u64,
    used: u64,
};

pub fn getMem() !mem {
    const cwd = std.fs.cwd();
    var buf: [2048]u8 = undefined;

    const readbuf = try cwd.readFile("/proc/meminfo", &buf);

    var total_kb: u64 = 0;
    var avail_kb: u64 = 0;

    var lines = std.mem.tokenizeSequence(u8, readbuf, "\n");
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "MemTotal:")) {
            total_kb = try parseMemValue(line);
        } else if (std.mem.startsWith(u8, line, "MemAvailable:")) {
            avail_kb = try parseMemValue(line);
        }
    }

    const total_gb = total_kb / 1024 / 1024;
    const avail_gb = avail_kb / 1024 / 1024;
    const used_gb = total_gb - avail_gb;

    return mem{
        .total = total_gb,
        .avail = avail_gb,
        .used = used_gb,
    };
}

fn parseMemValue(line: []const u8) !u64 {
    var parts = std.mem.tokenizeAny(u8, line, " \t:");
    _ = parts.next(); 
    const val_str = parts.next() orelse return error.InvalidFormat;
    return try std.fmt.parseInt(u64, val_str, 10);
}

pub fn getHost(get: std.mem.Allocator) ![]u8 {
    const file = try std.fs.cwd().openFile("/proc/sys/kernel/hostname", .{ .mode = .read_only });
    defer file.close();

    const hostname_raw = try file.reader().readAllAlloc(get, 256);
    errdefer get.free(hostname_raw);

    const hostname = std.mem.trim(u8, hostname_raw, " \n\r\t");

    if (hostname.len == hostname_raw.len) {
        return hostname_raw;
    }

    const hostname_cleaned = try get.alloc(u8, hostname.len);
    @memcpy(hostname_cleaned, hostname);
    get.free(hostname_raw);

    return hostname_cleaned;
}

// gasqu 0.1.1, create a output with CPU
pub fn utgc(gut: std.mem.Allocator) ![]u8
{
var buffer: [16384]u8 = undefined;

const readbuf = try std.fs.cwd().readFile("/proc/cpuinfo", &buffer);

if (std.mem.indexOf(u8, readbuf, "model name")) |index| 
{
        const line_slice = readbuf[index..];
        const end_index = std.mem.indexOf(u8, line_slice, "\n") orelse line_slice.len;
        const cpu_line = line_slice[0..end_index];

        return try gut.dupe(u8, cpu_line);
    }

    return try gut.dupe(u8, "Unknown CPU");
}
//gasqu 0.1.3, final the first component. output with GPU
pub fn getGpuModelName(allocator: std.mem.Allocator) ![]u8 {
    var dir = try std.fs.openDirAbsolute("/sys/class/drm", .{ .iterate = true });
    defer dir.close();

    var iterator = dir.iterate();
    var found_uevent: ?std.fs.File = null;
    defer if (found_uevent) |f| f.close();

    while (try iterator.next()) |entry| {
        if (entry.kind == .directory and std.mem.startsWith(u8, entry.name, "card") and !std.mem.containsAtLeast(u8, entry.name, 1, "-")) {
            var card_dir = try dir.openDir(entry.name, .{});
            defer card_dir.close();

            if (card_dir.openFile("device/uevent", .{})) |file| {
                found_uevent = file;
                break;
            } else |_| continue;
        }
    }

    const uevent_file = found_uevent or return error.GpuNotFound;

    const max_bytes = 4096;
    const content = try uevent_file.readToEndAlloc(allocator, max_bytes);
    defer allocator.free(content);

    var lines = std.mem.tokenizeSequence(u8, content, "\n");
    var pci_id_buf: [32]u8 = undefined;
    var pci_id: ?[]const u8 = null;

    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "PCI_ID=")) {
            pci_id = line["PCI_ID=".len..];
            break;
        } else if (std.mem.startsWith(u8, line, "PRODUCT=")) {
            const raw_prod = line["PRODUCT=".len..];
            var parts = std.mem.tokenizeSequence(u8, raw_prod, "/");
            const vendor = parts.next() orelse continue;
            const device = parts.next() orelse continue;
            pci_id = try std.fmt.bufPrint(&pci_id_buf, "{s}:{s}", .{ vendor, device });
            break;
        }
    }

    const id = pci_id or return error.GpuNotFound;

    var pci_ids_file = std.fs.openFileAbsolute("/usr/share/hwdata/pci.ids", .{}) catch
        std.fs.openFileAbsolute("/usr/share/misc/pci.ids", .{}) orelse
        return try allocator.dupe(u8, id);
    defer pci_ids_file.close();

    const ids_content = try pci_ids_file.readToEndAlloc(allocator, 1024 * 1024 * 4);
    defer allocator.free(ids_content);

    var id_parts = std.mem.tokenizeSequence(u8, id, ":");
    const vendor_target = id_parts.next() orelse return error.InvalidPciId;
    const device_target = id_parts.next() orelse return error.InvalidPciId;

    var ids_lines = std.mem.splitSequence(u8, ids_content, "\n");
    var current_vendor: ?[]const u8 = null;
    var vendor_name: ?[]const u8 = null;
    var device_name: ?[]const u8 = null;

    while (ids_lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;

        if (line[0] != '\t') {
            var parts = std.mem.tokenizeSequence(u8, line, " ");
            current_vendor = parts.next() orelse continue;
            if (std.mem.eql(u8, current_vendor.?, vendor_target)) {
                vendor_name = std.mem.trim(u8, line[current_vendor.?.len..], " ");
            } else {
                vendor_name = null;
            }
        } else if (vendor_name != null and line[0] == '\t' and line[1] != '\t') {
            var parts = std.mem.tokenizeSequence(u8, line[1..], " ");
            const current_device = parts.next() orelse continue;
            if (std.mem.eql(u8, current_device, device_target)) {
                device_name = std.mem.trim(u8, line[1 + current_device.len..], " ");
                break;
            }
        }
    }

    if (vendor_name) |v| {
        if (device_name) |d| {
            return try std.fmt.allocPrint(allocator, "{s} {s}", .{ v, d });
        }
    }

    return try allocator.dupe(u8, id);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const gut = gpa.allocator();

    const system_info = try getNameVers(allocator);
    defer allocator.free(system_info);

    const highway_cores = try readCpuCores();
    const ram = try getMem();
    
    const host_info = try getHost(allocator);
    defer allocator.free(host_info);

    const namecpu_info = try utgc(gut);
    defer gut.free(namecpu_info);

    const gpu_name = getGpuModelName(allocator) catch |err| {
        std.debug.print("Failed to fetch GPU model name: {}\n", .{err});
        return;
    };
    defer allocator.free(gpu_name);

    std.debug.print("Hostname:\t{s}\n", .{host_info});
    std.debug.print("System info:\t{s}\n", .{system_info});
    std.debug.print("GPU: {s}\n", .{gpu_name});
    std.debug.print("CPU: {s}\n", .{namecpu_info});
    std.debug.print("CPU's cores quantum:\t{}\n", .{highway_cores});
    std.debug.print("RAM Total:\t{} GB\n", .{ram.total});
    std.debug.print("RAM Available:\t{} GB\n", .{ram.avail});
    std.debug.print("RAM Used:\t{} GB\n", .{ram.used});
}
