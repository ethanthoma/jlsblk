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

list_directory :: (path: string) -> [..]string {
    names: [..]string;
    visit_files(path, false, *names, collect_name, visit_directories = true);
    return names;
}

get_disk_byte_size :: (disk_path: string) -> int {
    size_path := sprint("%/size", disk_path);
    text, ok := read_entire_file(size_path);
    if !ok then return 0;
    sectors := to_integer(trim(text));
    return sectors * SECTOR_SIZE;
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

get_mounts :: (partition_name: string) -> [..]string {
    mounts: [..]string;

    text, ok := read_entire_file("/proc/mounts");
    if !ok then return mounts;

    lines := split(text, "\n");
    for line : lines {
        if equal(line, "") then continue;

        fields := split(line, " ");

        if fields.count < 3 then continue;

        dev := fields[0];

        if !begins_with(dev, "/dev/") then continue;
        if !equal(partition_name, basename(dev)) then continue;

        mount := replace(fields[1], "\\040", " ");
        array_add(*mounts, mount);
    }

    return mounts;
}

Partition :: struct {
    name:   string;
    size:   string;
    mounts: [..]string;
}

get_partitions :: (disk_path: string) -> [..]Partition {
    partitions: [..]Partition;
    partition_names := list_directory(disk_path);
    quick_sort(partition_names);
    for partition_name : partition_names {
        sub_path := sprint("%/%", disk_path, partition_name);

        if !file_exists(sprint("%/partition", sub_path)) then continue;

        size := byte_size_to_human_readable_size(get_disk_byte_size(sub_path));
        mounts := get_mounts(partition_name);
        array_add(*partitions, .{partition_name, size, mounts});
    }
    return partitions;
}

Disk :: struct {
    name:     string;
    size:     string;
    children: [..]Partition;
}

get_disks :: () -> [..]Disk {
    disks: [..]Disk;
    disk_names := list_directory(SYS_BLOCK);
    quick_sort(disk_names);
    for disk_name : disk_names {
        disk_path := sprint("%/%", SYS_BLOCK, disk_name);

        disk_byte_size := get_disk_byte_size(disk_path);
        disk_human_size := byte_size_to_human_readable_size(disk_byte_size);

        partitions := get_partitions(disk_path);

        array_add(*disks, .{disk_name, disk_human_size, partitions});
    }
    return disks;
}

BOX_VERTICAL           :: "│";
BOX_UP_AND_RIGHT       :: "└";
BOX_VERTICAL_AND_RIGHT :: "├";
BOX_HORIZONTAL         :: "─";

main :: () {
    for disk : get_disks() {
        print("% %\n", disk.name, disk.size);
        for part : disk.children print("  % % %\n", part.name, part.size, join(.. part.mounts, separator = ", "));
    }
}
