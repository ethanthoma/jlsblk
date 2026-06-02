#import "Basic";
#import "File_Utilities";
#import "Sort";
#import "String";

SYS_BLOCK :: "/sys/block";
SECTOR_SIZE :: 512;

collect_name :: (info: *File_Visit_Info, names: *[..]string) {
    if begins_with(info.short_name, "loop") then return;
    array_add(names, copy_string(info.short_name));
}

list_directory :: (path: string) -> (names: [..]string) {
    visit_files(path, false, *names, collect_name, visit_directories = true);
    return names;
}

read_trimmed :: (path: string) -> (value: string = "", ok: bool = true) {
    text, ok := read_entire_file(path);
    if !ok then return value, ok;
    value = trim(text);
    return value, ok;
}

get_byte_size :: (sys_path: string) -> (byte_size: int = 0, ok: bool = true) {
    text, ok := read_trimmed(sprint("%/size", sys_path));
    if !ok then return byte_size, ok;
    byte_size := to_integer(text) * SECTOR_SIZE;
    return byte_size, ok;
}

byte_size_to_human_readable_size :: (size: int) -> string {
    divisor, unit := 1, "B";
    for string.["K", "M", "G", "T", "P"] {
        if size < divisor * 1024 break;
        divisor *= 1024;
        unit = it;
    }
    total := (size * 10 + divisor / 2) / divisor;
    return sprint("%.%%", total / 10, total % 10, unit);
}

basename :: (path: string) -> string {
    parts := split(path, "/");
    return parts[parts.count - 1];
}

Mount :: struct {
    device: string;
    point:  string;
}

unescape_mount :: (s: string) -> string {
    out := replace(s, "\\040", " ");
    out = replace(out, "\\011", "\x09");
    out = replace(out, "\\012", "\x0a");
    out = replace(out, "\\134", "\\");
    return out;
}

read_mounts :: () -> (mounts: [..]Mount) {
    text, ok := read_entire_file("/proc/mounts");
    if !ok then return mounts;

    for line : split(text, "\n") {
        if equal(line, "") then continue;

        fields := split(line, " ");
        if (fields.count < 3) then continue;

        dev := fields[0];
        if !begins_with(dev, "/dev/") then continue;

        array_add(*mounts, .{basename(dev), unescape_mount(fields[1])});
    }

    return mounts;
}

get_mounts :: (device_name: string, all_mounts: [..]Mount) -> (points: [..]string) {
    for * m : all_mounts {
        if equal(m.device, device_name) then array_add(*points, m.point);
    }
    return points;
}

device_kind :: (sys_path: string) -> string {
    if file_exists(sprint("%/partition", sys_path)) then return "part";
    uuid, ok := read_trimmed(sprint("%/dm/uuid", sys_path));
    if ok {
        prefix := split(uuid, "-")[0];
        if equal(prefix, "CRYPT") then return "crypt";
        if equal(prefix, "LVM")   then return "lvm";
        return prefix;
    }
    return "disk";
}

Device :: struct {
    name:     string;
    size:     string;
    kind:     string;
    mounts:   [..]string;
    children: [..]Device;
}

add_device :: (out: *[..]Device, sys_path: string, entry_name: string, all_mounts: [..]Mount) {
    name := entry_name;
    dm_name, has_dm := read_trimmed(sprint("%/dm/name", sys_path));
    if has_dm then name = dm_name;

    byte_size, ok := get_byte_size(sys_path);
    if !ok then print("WARNING: failed to get size for %\n", name);

    children: [..]Device;

    partitions := list_directory(sys_path);
    quick_sort(partitions);
    for partition : partitions {
        sub_path := sprint("%/%", sys_path, partition);
        if !file_exists(sprint("%/partition", sub_path)) then continue;
        add_device(*children, sub_path, partition, all_mounts);
    }

    holders := list_directory(sprint("%/holders", sys_path));
    quick_sort(holders);
    for holder : holders {
        add_device(*children, sprint("%/%", SYS_BLOCK, holder), holder, all_mounts);
    }

    size := byte_size_to_human_readable_size(byte_size);
    kind := device_kind(sys_path);
    mounts := get_mounts(name, all_mounts);
    array_add(out, .{name, size, kind, mounts, children});
}

get_devices :: () -> (devices: [..]Device) {
    all_mounts := read_mounts();
    names := list_directory(SYS_BLOCK);
    quick_sort(names);
    for name : names {
        sys_path := sprint("%/%", SYS_BLOCK, name);
        slaves := list_directory(sprint("%/slaves", sys_path));
        if slaves.count > 0 then continue;
        add_device(*devices, sys_path, name, all_mounts);
    }
    return devices;
}

BOX_VERTICAL           :: "│";
BOX_UP_AND_RIGHT       :: "└";
BOX_VERTICAL_AND_RIGHT :: "├";
BOX_VERTICAL_AND_LEFT  :: "┤";
BOX_HORIZONTAL         :: "─";
BOX_TOP_LEFT           :: "╭";
BOX_TOP_RIGHT          :: "╮";
BOX_BOTTOM_LEFT        :: "╰";
BOX_BOTTOM_RIGHT       :: "╯";
BOX_T_DOWN             :: "┬";
BOX_T_UP               :: "┴";
BOX_CROSS              :: "┼";

display_width :: (s: string) -> (w: int = 0) {
    for i : 0..s.count - 1 {
        if (s[i] & 0xC0) != 0x80 then w += 1;
    }
    return w;
}

repeat :: (n: int, s := " ") -> (result: string = "") {
    for 1..n {
        result = sprint("%%", result, s);
    }
    return result;
}

pad_right :: (s: string, width: int) -> string {
    return sprint("%%", s, repeat(width - display_width(s)));
}

pad_left :: (s: string, width: int) -> string {
    return sprint("%%", repeat(width - display_width(s)), s);
}

isatty :: (fd: s32) -> s32 #foreign;

RESET :: "\x1b[0m";
DIM   :: "\x1b[2m";

color_for_kind :: (kind: string) -> string {
    if equal(kind, "disk")  then return "\x1b[1m";      // bold
    if equal(kind, "crypt") then return "\x1b[1;33m";   // bold yellow
    if equal(kind, "lvm")   then return "\x1b[1;35m";   // bold magenta
    return "";
}

colorize :: (s: string, kind: string, use_color: bool) -> string {
    if !use_color then return s;
    color := color_for_kind(kind);
    if color.count == 0 then return s;
    return sprint("%%%", color, s, RESET);
}

dim :: (s: string, use: bool) -> string {
    if !use then return s;
    return sprint("%%%", DIM, s, RESET);
}

Row :: struct {
    name:   string;
    size:   string;
    kind:   string;
    mounts: string;
    prefix: string;
    top:    bool;
}

build_rows :: (device: *Device, prefix: string, is_root: bool, is_last: bool, rows: *[..]Row) {
    name := device.name;
    connector := "";
    if !is_root {
        connector = sprint("%%", BOX_VERTICAL_AND_RIGHT, BOX_HORIZONTAL);
        if is_last then connector = sprint("%%", BOX_UP_AND_RIGHT, BOX_HORIZONTAL);
    }
    mounts := join(.. device.mounts, separator = ", ");
    array_add(rows, .{name, device.size, device.kind, mounts, sprint("%%", prefix, connector), is_root});

    child_prefix := "";
    if !is_root {
        continuation := sprint("%%", BOX_VERTICAL, " ");
        if is_last then continuation = "  ";
        child_prefix = sprint("%%", prefix, continuation);
    }

    count := device.children.count;
    for i : 0..count - 1 {
        build_rows(*device.children[i], child_prefix, false, i == count - 1, rows);
    }
}

Cols :: struct {
    name:  int;
    size:  int;
    kind:  int;
    mount: int;
}

print_rule :: (left: string, mid: string, right: string, c: Cols) {
    print("%", left);
    print("%", repeat(c.name + 2, BOX_HORIZONTAL));
    print("%", mid);
    print("%", repeat(c.size + 2, BOX_HORIZONTAL));
    print("%", mid);
    print("%", repeat(c.kind + 2, BOX_HORIZONTAL));
    print("%", mid);
    print("%", repeat(c.mount + 2, BOX_HORIZONTAL));
    print("%\n", right);
}

print_row :: (r: *Row, c: Cols, tty: bool, header: bool) {
    namepad := repeat(c.name - display_width(r.prefix) - display_width(r.name));
    name := colorize(r.name, r.kind, tty);

    if !tty {
        if r.mounts.count > 0 {
            print("%%% % % %\n", r.prefix, name, namepad, pad_left(r.size, c.size), pad_right(r.kind, c.kind), r.mounts);
        } else {
            print("%%% % %\n", r.prefix, name, namepad, pad_left(r.size, c.size), r.kind);
        }
        return;
    }

    type_cell := dim(pad_right(r.kind, c.kind), !header);
    print("% %%% ", BOX_VERTICAL, r.prefix, name, namepad);
    print("% % ", BOX_VERTICAL, pad_left(r.size, c.size));
    print("% % ", BOX_VERTICAL, type_cell);
    print("% % ", BOX_VERTICAL, pad_right(r.mounts, c.mount));
    print("%\n", BOX_VERTICAL);
}

render :: (devices: [..]Device) {
    rows: [..]Row;
    array_add(*rows, .{"NAME", "SIZE", "TYPE", "MOUNTPOINTS", "", false});

    count := devices.count;
    if count > 0 {
        for i : 0..count - 1 {
            build_rows(*devices[i], "", true, i == count - 1, *rows);
        }
    }

    name_width, size_width, kind_width, mount_width := 0, 0, 0, 0;
    for * r : rows {
        name_width = max(name_width, display_width(r.prefix) + display_width(r.name));
        size_width = max(size_width, display_width(r.size));
        kind_width = max(kind_width, display_width(r.kind));
        mount_width = max(mount_width, display_width(r.mounts));
    }
    c: Cols = .{name_width, size_width, kind_width, mount_width};

    tty := isatty(1) != 0;

    if tty then print_rule(BOX_TOP_LEFT, BOX_T_DOWN, BOX_TOP_RIGHT, c);
    print_row(*rows[0], c, tty, true);
    if tty then print_rule(BOX_VERTICAL_AND_RIGHT, BOX_CROSS, BOX_VERTICAL_AND_LEFT, c);

    seen_top := false;
    for i : 1..rows.count - 1 {
        r := *rows[i];
        if r.top {
            if seen_top {
                if tty then print_rule(BOX_VERTICAL_AND_RIGHT, BOX_CROSS, BOX_VERTICAL_AND_LEFT, c);
                else print("\n");
            }
            seen_top = true;
        }
        print_row(r, c, tty, false);
    }

    if tty then print_rule(BOX_BOTTOM_LEFT, BOX_T_UP, BOX_BOTTOM_RIGHT, c);
}

main :: () {
    render(get_devices());
}
