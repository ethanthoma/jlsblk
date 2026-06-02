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
    s, unit := size, "B";
    for string.["K", "M", "G", "T", "P"] {
        if s < 1024 break;
        s, unit = s / 1024, it;
    }
    return sprint("%%", s, unit);
}

basename :: (path: string) -> string {
    parts := split(path, "/");
    return parts[parts.count - 1];
}

get_mounts :: (device_name: string) -> (mounts: [..]string) {
    text, ok := read_entire_file("/proc/mounts");
    if !ok then return mounts;

    for line : split(text, "\n") {
        if equal(line, "") then continue;

        fields := split(line, " ");
        if (fields.count < 3) then continue;

        dev := fields[0];
        if !begins_with(dev, "/dev/") then continue;
        if !equal(device_name, basename(dev)) then continue;

        array_add(*mounts, replace(fields[1], "\\040", " "));
    }

    return mounts;
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

add_device :: (out: *[..]Device, sys_path: string, entry_name: string) {
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
        add_device(*children, sub_path, partition);
    }

    holders := list_directory(sprint("%/holders", sys_path));
    quick_sort(holders);
    for holder : holders {
        add_device(*children, sprint("%/%", SYS_BLOCK, holder), holder);
    }

    size := byte_size_to_human_readable_size(byte_size);
    kind := device_kind(sys_path);
    mounts := get_mounts(name);
    array_add(out, .{name, size, kind, mounts, children});
}

get_devices :: () -> (devices: [..]Device) {
    names := list_directory(SYS_BLOCK);
    quick_sort(names);
    for name : names {
        sys_path := sprint("%/%", SYS_BLOCK, name);
        slaves := list_directory(sprint("%/slaves", sys_path));
        if slaves.count > 0 then continue;
        add_device(*devices, sys_path, name);
    }
    return devices;
}

print_device :: (device: *Device, indent: string) {
    print("%", indent);
    print("% % %", device.name, device.size, device.kind);
    mounts := join(.. device.mounts, separator = ", ");
    if mounts.count > 0 then print(" %", mounts);
    print("\n");

    child_indent := sprint("%  ", indent);
    for device.children print_device(*it, child_indent);
}

BOX_VERTICAL           :: "│";
BOX_UP_AND_RIGHT       :: "└";
BOX_VERTICAL_AND_RIGHT :: "├";
BOX_HORIZONTAL         :: "─";

main :: () {
    for get_devices() print_device(*it, "");
}
