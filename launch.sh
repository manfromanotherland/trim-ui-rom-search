#!/bin/sh

DIR="$(dirname "$0")"
cd "$DIR" || exit 1

# Process cleanup function
cleanup() {
    # Remove stay awake flag
    rm -f /tmp/stay_awake

    # Kill any background processes we started
    jobs -p | xargs -r kill

    # Kill any lingering processes
    killall -9 "build_cache"

    # Kill our parent process to ensure complete exit
    kill -9 $PPID

    # Clear screen on exit
    clear
}

# Handle all exit cases
trap cleanup EXIT INT TERM HUP QUIT

# Setup required paths
export SDCARD_PATH="/mnt/SDCARD"
export BIOS_PATH="$SDCARD_PATH/Bios"
export SAVES_PATH="$SDCARD_PATH/Saves"
export USERDATA_PATH="$SDCARD_PATH/.userdata"
export LOGS_PATH="$SDCARD_PATH/Logs"

# Cache setup
CACHE_DIR="$USERDATA_PATH/romsearch"
CACHE_FILE="$CACHE_DIR/cache.txt"

# Setup logging
mkdir -p "$DIR/log"
[ -f "$DIR/log/launch.log" ] && mv "$DIR/log/launch.log" "$DIR/log/launch.log.old"

clean_rom_name() {
    basename "${1%.*}"
}

add_to_recent() {
    rom_path="$1"
    rom_path_rel="${rom_path#$SDCARD_PATH}"  # Remove SDCARD_PATH prefix
    display_name=$(clean_rom_name "$rom_path")

    # Create recent.txt if it doesn't exist
    recent_file="$SDCARD_PATH/.userdata/shared/.minui/recent.txt"
    mkdir -p "$(dirname "$recent_file")"
    touch "$recent_file"

    # Add new entry at the top
    echo -e "${rom_path_rel}\t${display_name}" > "$recent_file.tmp"
    cat "$recent_file" >> "$recent_file.tmp"
    mv "$recent_file.tmp" "$recent_file"
}

launch_rom() {
    rom_path="$1"
    echo "Attempting to launch: $rom_path" >> "$DIR/log/launch.log"

    # Extract emulator name from parent directory name
    parent_dir=$(dirname "$rom_path")
    emu=$(echo "$parent_dir" | sed -n 's/.*(\([^)]*\)).*/\1/p')
    echo "Extracted emulator: $emu" >> "$DIR/log/launch.log"

    if [ -n "$emu" ]; then
        # Try system paks first
        system_pak="$SDCARD_PATH/.system/tg5040/paks/Emus/${emu}.pak"
        system_launch="$system_pak/launch.sh"

        # If not in system, try external paks
        external_pak="$SDCARD_PATH/Emus/tg5040/${emu}.pak"
        external_launch="$external_pak/launch.sh"

        # Check system pak first
        if [ -f "$system_launch" ]; then
            echo "Launching from system pak..." >> "$DIR/log/launch.log"
            add_to_recent "$rom_path"
            "$system_launch" "$rom_path"
            return 2
        # Fall back to external pak
        elif [ -f "$external_launch" ]; then
            echo "Launching from external pak..." >> "$DIR/log/launch.log"
            add_to_recent "$rom_path"
            "$external_launch" "$rom_path"
            return 2
        else
            echo "Emulator not found in system or external paks" >> "$DIR/log/launch.log"
        fi
    else
        echo "Could not extract emulator name!" >> "$DIR/log/launch.log"
    fi
    return 1
}

search_screen() {
    last_search_term=${1:-""}

    search_term="$("$DIR/bin/minui-keyboard-tg5040" \
        --header "Rom Search" \
        --initial-value "$last_search_term")"
    exit_code=$?

    # Handle MENU button (exit)
    if [ "$exit_code" -eq 3 ]; then
        cleanup
        exit 0
    fi

    if [ -n "$search_term" ]; then
        # Create temporary file for results
        results_file="/tmp/rom_results.txt"
        paths_file="/tmp/rom_paths.txt"

        # Make sure files are empty
        : > "$results_file"
        : > "$paths_file"

        # Find ROMs and store results
        find "$SDCARD_PATH/Roms" -type f \
            ! -path "*.disabled/*" \
            ! -path "*/PORTS/*" \
            ! -name ".*" \
            -iname "*$search_term*" > "$paths_file"

        # Generate display names from paths
        if [ -s "$paths_file" ]; then
            while IFS= read -r file; do
                clean_name=$(clean_rom_name "$file")
                echo "$clean_name:$file" >> "$results_file"
            done < "$paths_file"

            # Sort by clean name
            sort -t: -k1 "$results_file" -o "$results_file"

            # Split display names and paths
            cut -d: -f1 "$results_file" > "$results_file.display"
            cut -d: -f2 "$results_file" > "$paths_file.sorted"
            mv "$results_file.display" "$results_file"
            mv "$paths_file.sorted" "$paths_file"

            echo "Found $(wc -l < "$results_file") results" >> "$DIR/log/launch.log"
        else
            echo "No results found, try again" > "$results_file"
            echo "No results found" >> "$DIR/log/launch.log"
        fi

        # Show results and capture selection
        selected=$("$DIR/bin/minui-list-tg5040" \
            --file "$results_file" \
            --format text \
            --header "Search Results: $search_term")
        list_exit=$?
        echo "Selected: $selected" >> "$DIR/log/launch.log"
        echo "List exit code: $list_exit" >> "$DIR/log/launch.log"

        # Handle MENU button in list (exit)
        if [ "$list_exit" -eq 3 ]; then
            rm -f "$results_file" "$paths_file"
            cleanup
            exit 0
        fi

        # Handle selection
        if [ "$list_exit" -eq 0 ] && [ -n "$selected" ]; then
            if [ "$selected" = "No results found, try again" ]; then
                rm -f "$results_file" "$paths_file"
                return 2
            fi

            # Get the path from the same line number as the selection
            selected_line=$(grep -n "^$selected$" "$results_file" | cut -d: -f1)
            if [ -n "$selected_line" ]; then
                selected_path=$(sed -n "${selected_line}p" "$paths_file")
                echo "Selected path: $selected_path" >> "$DIR/log/launch.log"
                if [ -n "$selected_path" ]; then
                    rm -f "$results_file" "$paths_file"
                    launch_rom "$selected_path"
                    return $?
                fi
            fi
        fi

        rm -f "$results_file" "$paths_file"
        return $list_exit
        # B button pressed in results, return to keyboard with same term
        search_screen "$search_term"  # Keep the same search term
        return $?
    fi

    return 2  # Return to search if empty search
}

# Build cache in background if needed
if [ ! -f "$CACHE_FILE" ]; then
    build_cache &
fi

# Main loop
{
    while true; do
        search_screen
        exit_code=$?
        # Handle B button to continue search
        [ "$exit_code" -eq 2 ] && continue
        # Any other exit code should exit the app
        break
    done
} > "$DIR/log/launch.log" 2>&1

# Cleanup
rm -f /tmp/rom_results.txt /tmp/rom_paths.txt
