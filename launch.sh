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
    pkill -f "build_cache"

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

build_cache() {
    mkdir -p "$CACHE_DIR"
    find "$SDCARD_PATH/Roms" -maxdepth 2 -type f \
        ! -path "*.disabled/*" \
        ! -path "*/PORTS/*" \
        ! -name ".*" > "$CACHE_FILE.tmp"
    mv "$CACHE_FILE.tmp" "$CACHE_FILE"
}

# Build cache in background if needed
if [ ! -f "$CACHE_FILE" ]; then
    build_cache &
fi

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
            exec "$system_launch" "$rom_path"
        # Fall back to external pak
        elif [ -f "$external_launch" ]; then
            echo "Launching from external pak..." >> "$DIR/log/launch.log"
            exec "$external_launch" "$rom_path"
        else
            echo "Emulator not found in system or external paks" >> "$DIR/log/launch.log"
        fi
    else
        echo "Could not extract emulator name!" >> "$DIR/log/launch.log"
    fi
    return 1
}

search_screen() {
    # Show keyboard and get input
    search_term="$("$DIR/bin/minui-keyboard-tg5040" --header "Enter ROM Search")"
    exit_code=$?

    # Handle Y button or MENU button (exit)
    if [ "$exit_code" -eq 3 ]; then
        cleanup
        exit 0
    fi

    # Handle B button (back)
    if [ "$exit_code" -eq 2 ]; then
        return 2
    fi

    if [ -n "$search_term" ]; then
        # Create temporary file for results
        results_file="/tmp/rom_results.txt"
        paths_file="/tmp/rom_paths.txt"

        # Make sure files are empty
        : > "$results_file"
        : > "$paths_file"

        # Wait for cache if it's still building
        while [ ! -f "$CACHE_FILE" ]; do
            sleep 0.1
        done

        # Search using cache
        grep -i "$search_term" "$CACHE_FILE" | sort -u > "$paths_file"

        # Generate display names from paths
        if [ -s "$paths_file" ]; then
            while IFS= read -r file; do
                basename "${file%.*}" >> "$results_file"
            done < "$paths_file"

            # Sort results (unique only)
            sort -u "$results_file" -o "$results_file"
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

        # Handle Y button or MENU button in list screen
        if [ "$list_exit" -eq 3 ]; then
            cleanup
            exit 0
        fi

        # Handle selection
        if [ "$list_exit" -eq 0 ] && [ -n "$selected" ]; then
            if [ "$selected" = "No results found, try again" ]; then
                rm -f "$results_file" "$paths_file"
                return 2
            fi

            # Find the matching ROM path
            selected_path=$(grep "/$selected\." "$paths_file")
            echo "Selected path: $selected_path" >> "$DIR/log/launch.log"
            if [ -n "$selected_path" ]; then
                rm -f "$results_file" "$paths_file"
                launch_rom "$selected_path"
                return $?
            fi
        fi

        rm -f "$results_file" "$paths_file"
        return $list_exit
    fi

    return 2  # Return to search if empty search
}

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
