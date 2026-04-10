#!/bin/bash

main_import_photos() {
    local src="/run/media/simon/disk/DCIM/100MSDCF"
    local dest="/home/simon/photos/raw"

    if [ ! -d "$src" ]; then
        echo "❌ Källmapp hittades inte: $src"
        return 1
    fi

    mkdir -p "$dest"

    local count
    count=$(find "$src" -maxdepth 1 -name "*.ARW" -type f | wc -l)

    if [ "$count" -eq 0 ]; then
        echo "Inga .ARW filer hittades i $src"
        return 0
    fi

    echo "Flyttar $count .ARW filer..."

    find "$src" -maxdepth 1 -name "*.ARW" -type f | while read -r file; do
        local filename
        local filedate
        local targetdir

        filename=$(basename "$file")
        filedate=$(stat -c %y "$file" | cut -d' ' -f1)
        targetdir="$dest/$filedate"

        mkdir -p "$targetdir"
        mv -v "$file" "$targetdir/"
    done

    echo "Klart! $count filer flyttade till $dest"
}

main_photos() {
    main_import_photos
}
