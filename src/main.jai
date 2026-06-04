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

Mount :: struct {
    majmin: string;
    point:  string;
}

unescape_mount :: (s: string) -> (out: string = s) {
    out = replace(out, "\\040", " ");
    out = replace(out, "\\011", "\x09");
    out = replace(out, "\\012", "\x0a");
    out = replace(out, "\\134", "\\");
    return out;
}

read_mounts :: () -> (mounts: [..]Mount) {
    text, ok := read_entire_file("/proc/self/mountinfo");
    if !ok then return mounts;

    for line : split(text, "\n") {
        if equal(line, "") then continue;

        fields := split(line, " ");
        if (fields.count < 5) then continue;

        array_add(*mounts, .{fields[2], unescape_mount(fields[4])});
    }

    return mounts;
}

get_mounts :: (majmin: string, all_mounts: [..]Mount) -> (points: [..]string) {
    for * m : all_mounts {
        if equal(m.majmin, majmin) then array_add(*points, m.point);
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
    majmin, _ := read_trimmed(sprint("%/dev", sys_path));
    mounts := get_mounts(majmin, all_mounts);
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

Statvfs :: struct {
    f_bsize:   int;
    f_frsize:  int;
    f_blocks:  int;
    f_bfree:   int;
    f_bavail:  int;
    f_files:   int;
    f_ffree:   int;
    f_favail:  int;
    f_fsid:    int;
    f_flag:    int;
    f_namemax: int;
    f_spare:   [6] s32;
}

statvfs :: (path: *u8, buf: *Statvfs) -> s32 #foreign;

disk_usage :: (mount: string) -> (avail: string = "", usep: string = "", avail_bytes: int = 0) {
    buf: Statvfs;

    if statvfs(to_c_string(mount), *buf) != 0 then return "", "", 0;
    if buf.f_blocks == 0 then return "", "", 0;

    used := buf.f_blocks - buf.f_bfree;
    denom := used + buf.f_bavail;

    if denom <= 0 then return "", "", 0;

    pct := (used * 100 + denom - 1) / denom;
    bytes := buf.f_bavail * buf.f_frsize;
    return byte_size_to_human_readable_size(bytes), sprint("%\%", pct), bytes;
}

RESET :: "\x1b[0m";
DIM   :: "\x1b[2m";
BOLD  :: "\x1b[1m";

// Palette (24-bit truecolor)
GREEN   :: "\x1b[38;2;0;174;107m";
RED     :: "\x1b[38;2;242;40;60m";
BLUE    :: "\x1b[38;2;0;102;204m";
CYAN    :: "\x1b[38;2;0;161;180m";
YELLOW  :: "\x1b[38;2;255;194;0m";
MAGENTA :: "\x1b[38;2;215;46;130m";
VIOLET  :: "\x1b[38;2;135;90;251m";
ORANGE  :: "\x1b[38;2;255;122;0m";

ColorMode :: enum { AUTO; NONE; ANSI; TRUE; }
Hue       :: enum { GREEN; RED; YELLOW; MAGENTA; }

hue_code :: (h: Hue, mode: ColorMode) -> string {
    if mode == .NONE then return "";

    if h == {
        case .GREEN;   return ifx mode == .TRUE then GREEN   else "\x1b[32m";
        case .RED;     return ifx mode == .TRUE then RED     else "\x1b[31m";
        case .YELLOW;  return ifx mode == .TRUE then YELLOW  else "\x1b[33m";
        case .MAGENTA; return ifx mode == .TRUE then MAGENTA else "\x1b[35m";
    }

    return "";
}

color_for_kind :: (kind: string, mode: ColorMode) -> string {
    if mode == .NONE        then return "";
    if equal(kind, "disk")  then return BOLD;
    if equal(kind, "crypt") then return sprint("%%", BOLD, hue_code(.YELLOW, mode));
    if equal(kind, "lvm")   then return sprint("%%", BOLD, hue_code(.MAGENTA, mode));
    return "";
}

colorize :: (s: string, kind: string, mode: ColorMode) -> string {
    color := color_for_kind(kind, mode);
    if color.count == 0 then return s;
    return sprint("%%%", color, s, RESET);
}

dim :: (s: string, mode: ColorMode) -> string {
    if mode == .NONE then return s;
    return sprint("%%%", DIM, s, RESET);
}

GIB :: 1024 * 1024 * 1024;

color_for_avail :: (bytes: int, mode: ColorMode) -> string {
    if bytes < 1  * GIB then return hue_code(.RED, mode);
    if bytes < 10 * GIB then return hue_code(.YELLOW, mode);
    return hue_code(.GREEN, mode);
}

colorize_avail :: (s: string, bytes: int, mode: ColorMode) -> string {
    color := color_for_avail(bytes, mode);
    if color.count == 0 then return s;
    return sprint("%%%", color, s, RESET);
}

Row :: struct {
    name:        string;
    size:        string;
    kind:        string;
    mounts:      string;
    avail:       string;
    usep:        string;
    avail_bytes: int;
    prefix:      string;
    top:         bool;
}

build_rows :: (device: *Device, prefix: string, is_root: bool, is_last: bool, rows: *[..]Row) {
    name        := device.name;
    connector   := "";

    if !is_root {
        connector = sprint("%%", BOX_VERTICAL_AND_RIGHT, BOX_HORIZONTAL);
        if is_last then connector = sprint("%%", BOX_UP_AND_RIGHT, BOX_HORIZONTAL);
    }

    mounts      := join(.. device.mounts, separator = ", ");
    avail, usep := "", "";
    avail_bytes := 0;

    if device.mounts.count > 0 {
        a, u, ab := disk_usage(device.mounts[0]);
        avail = a;
        usep = u;
        avail_bytes = ab;
    }

    array_add(rows, .{name, device.size, device.kind, mounts, avail, usep, avail_bytes, sprint("%%", prefix, connector), is_root});

    child_prefix := "";

    if !is_root {
        continuation := sprint("%%", BOX_VERTICAL, " ");
        if is_last then continuation = "  ";
        child_prefix = sprint("%%", prefix, continuation);
    }

    count        := device.children.count;
    for i : 0..count - 1 {
        build_rows(*device.children[i], child_prefix, false, i == count - 1, rows);
    }
}

Field :: enum { NAME; SIZE; TYPE; AVAIL; USEP; MOUNT; }
Align :: enum { LEFT; RIGHT; }

Column :: struct {
    field: Field;
    align: Align;
}

COLUMNS :: Column.[
    .{.NAME,  .LEFT},
    .{.SIZE,  .RIGHT},
    .{.AVAIL, .RIGHT},
    .{.USEP,  .RIGHT},
    .{.TYPE,  .LEFT},
    .{.MOUNT, .LEFT},
];

cell :: (r: *Row, f: Field) -> string {
    if f == .NAME  then return r.name;
    if f == .SIZE  then return r.size;
    if f == .TYPE  then return r.kind;
    if f == .AVAIL then return r.avail;
    if f == .USEP  then return r.usep;
    return r.mounts;
}

cell_width :: (r: *Row, f: Field) -> int {
    w := display_width(cell(r, f));
    if f == .NAME then w += display_width(r.prefix);
    return w;
}

render_cell :: (r: *Row, col: Column, w: int, mode: ColorMode, header: bool) -> string {
    text := cell(r, col.field);
    if col.field == .NAME {
        gap := repeat(w - display_width(r.prefix) - display_width(text));
        return sprint("%%%", r.prefix, colorize(text, r.kind, mode), gap);
    }
    padded := pad_right(text, w);
    if col.align == .RIGHT then padded = pad_left(text, w);
    if col.field == .TYPE  && !header then padded = dim(padded, mode);
    if col.field == .AVAIL && !header && text.count > 0 then padded = colorize_avail(padded, r.avail_bytes, mode);
    return padded;
}

print_rule :: (left: string, mid: string, right: string, widths: [] int) {
    print("%", left);
    for w, i : widths {
        if i > 0 then print("%", mid);
        print("%", repeat(w + 2, BOX_HORIZONTAL));
    }
    print("%\n", right);
}

print_row :: (r: *Row, widths: [] int, tty: bool, mode: ColorMode, header: bool) {
    if tty {
        print("%", BOX_VERTICAL);
        for col, i : COLUMNS  print(" % %", render_cell(r, col, widths[i], mode, header), BOX_VERTICAL);
        print("\n");
        return;
    }

    line := "";
    for col, i : COLUMNS {
        if i > 0 then line = sprint("% ", line);
        line = sprint("%%", line, render_cell(r, col, widths[i], mode, header));
    }
    print("%\n", trim_right(line));
}

render :: (devices: [..]Device, mode: ColorMode) {
    rows: [..]Row;
    array_add(*rows, .{"NAME", "SIZE", "TYPE", "MOUNTPOINTS", "AVAIL", "USE%", 0, "", false});

    count := devices.count;
    if count > 0 {
        for i : 0..count - 1 {
            build_rows(*devices[i], "", true, i == count - 1, *rows);
        }
    }

    widths: [COLUMNS.count] int;
    for * r : rows {
        for col, i : COLUMNS  widths[i] = max(widths[i], cell_width(r, col.field));
    }

    tty := isatty(1) != 0;

    if tty then print_rule(BOX_TOP_LEFT, BOX_T_DOWN, BOX_TOP_RIGHT, widths);
    print_row(*rows[0], widths, tty, mode, true);
    if tty then print_rule(BOX_VERTICAL_AND_RIGHT, BOX_CROSS, BOX_VERTICAL_AND_LEFT, widths);

    seen_top := false;
    for i : 1..rows.count - 1 {
        r := *rows[i];
        if r.top {
            if seen_top {
                if tty then print_rule(BOX_VERTICAL_AND_RIGHT, BOX_CROSS, BOX_VERTICAL_AND_LEFT, widths);
                else print("\n");
            }
            seen_top = true;
        }
        print_row(r, widths, tty, mode, false);
    }

    if tty then print_rule(BOX_BOTTOM_LEFT, BOX_T_UP, BOX_BOTTOM_RIGHT, widths);
}

color_mode_from_string :: (value: string) -> ColorMode {
    if value == {
        case "never"; #through;
        case "none";                  return .NONE;
        case "ansi"; #through;
        case "terminal";              return .ANSI;
        case "true"; #through;
        case "builtin";               return .TRUE;
        case "auto";                  return .AUTO;
    }
    print("jlsblk: unknown --color value '%' (use auto|never|ansi|true)\n", value);
    return .AUTO;
}

resolve_color_mode :: () -> ColorMode {
    mode := ColorMode.AUTO;
    args := get_command_line_arguments();
    for i : 1..args.count - 1 {
        a := args[i];
        if begins_with(a, "--color=") {
            parts := split(a, "=");
            if parts.count >= 2 then mode = color_mode_from_string(parts[1]);
        } else if equal(a, "--color") && i + 1 < args.count {
            mode = color_mode_from_string(args[i + 1]);
        }
    }

    if mode == .AUTO {
        if isatty(1) != 0 then return .TRUE;
        return .NONE;
    }
    return mode;
}

main :: () {
    render(get_devices(), resolve_color_mode());
}
