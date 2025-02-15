#!/bin/sh

DIR="$(dirname "$0")"
cd "$DIR" || exit 1

# Process cleanup function
cleanup() {
    # Remove stay awake flag
    rm -f /tmp/stay_awake

    # Kill any background processes we started
    jobs -p | xargs -r kill 2>/dev/null || true

    # Kill any lingering processes
    killall -9 "build_cache" 2>/dev/null || true

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
CACHE_READY="/tmp/rom_cache_ready"

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

    # Check if the entry already exists
    if grep -q -F "${rom_path_rel}" "$recent_file"; then
        # If it's the first entry, do nothing
        first_entry=$(head -n 1 "$recent_file")
        if [ "$first_entry" == "${rom_path_rel}" ]; then
            return
        fi

        # If somewhere on the list move it to the top
        grep -v -F "${rom_path_rel}" "$recent_file" > "$recent_file.tmp"
        {
            echo -e "${rom_path_rel}\t${display_name}"
            cat "$recent_file.tmp"
        } > "$recent_file"
    else
        # Add new entry at the top
        echo -e "${rom_path_rel}\t${display_name}" > "$recent_file.tmp"
        cat "$recent_file" >> "$recent_file.tmp"
        mv "$recent_file.tmp" "$recent_file"
    fi
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
            show_message "Could not find '$emu' emulator!" 2
            echo "Emulator not found in system or external paks" >> "$DIR/log/launch.log"
        fi
    else
        show_message "Could not find emulator name." 2
        echo "Could not extract emulator name!" >> "$DIR/log/launch.log"
    fi
    return 1
}

show_results_screen() {
    local search_term="$1"
    local results_file="$2"
    local paths_file="$3"

    # Show results and capture selection
    num_results=$(wc -l < "$results_file")
    selected=$("$DIR/bin/minui-list-tg5040" \
        --file "$results_file" \
        --format text \
        --header "$num_results results for '$search_term'" \
        --confirm-button "A" \
        --confirm-text "OPEN" \
        --cancel-button "B" \
        --cancel-text "BACK")
    list_exit=$?
    
    echo "Selected: $selected" >> "$DIR/log/launch.log"
    echo "List exit code: $list_exit" >> "$DIR/log/launch.log"

    # Handle MENU button (exit)
    if [ "$list_exit" -eq 3 ]; then
        rm -f "$results_file" "$paths_file"
        cleanup
        exit 0
    fi

    # Handle selection
    if [ "$list_exit" -eq 0 ] && [ -n "$selected" ]; then
        # Get the path from the same line number as the selection
        selected_line=$(grep -n "^$selected$" "$results_file" | cut -d: -f1)
        if [ -n "$selected_line" ]; then
            selected_path=$(sed -n "${selected_line}p" "$paths_file")
            if [ -n "$selected_path" ]; then
                launch_rom "$selected_path"
                # After game exits, show results again recursively
                show_results_screen "$search_term" "$results_file" "$paths_file"
                return $?
            fi
        fi
    fi

    # B button pressed, return to keyboard
    return 1
}

show_message() {
    message="$1"
    seconds="$2"

    if [ -z "$seconds" ]; then
        seconds="forever"
    fi

    killall sdl2imgshow
    echo "$message" 1>&2
    if [ "$seconds" = "forever" ]; then
        "$DIR/bin/sdl2imgshow" \
            -i "$DIR/res/background.png" \
            -f "$DIR/res/fonts/BPreplayBold.otf" \
            -s 27 \
            -c "220,220,220" \
            -q \
            -t "$message" >/dev/null 2>&1 &
    else
        "$DIR/bin/sdl2imgshow" \
            -i "$DIR/res/background.png" \
            -f "$DIR/res/fonts/BPreplayBold.otf" \
            -s 27 \
            -c "220,220,220" \
            -q \
            -t "$message" >/dev/null 2>&1
        sleep "$seconds"
    fi
}

search_screen() {
    last_search_term=${1:-""}

    search_term="$("$DIR/bin/minui-keyboard-tg5040" \
        --header "ROM Search" \
        --initial-value "$last_search_term")"
    exit_code=$?

    # Handle MENU button (exit)
    if [ "$exit_code" -eq 3 ]; then
        cleanup
        exit 0
    fi

    if [ -n "$search_term" ]; then
        # Check search term length
        if [ ${#search_term} -le 2 ]; then
            show_message "Minimum 3 characters needed!" 2
            search_screen "$search_term"
            return $?
        fi

        # Create temporary file for results
        results_file="/tmp/rom_results.txt"
        paths_file="/tmp/rom_paths.txt"

        # Make sure files are empty
        : > "$results_file"
        : > "$paths_file"

        # Check if cache is ready
        if [ ! -f "$CACHE_READY" ]; then
            show_message "Caching ROM files..." forever &
            loading_pid=$!
            while [ ! -f "$CACHE_READY" ]; do
                sleep 0.1
            done
            kill $loading_pid 2>/dev/null
        fi

        # Show loading message
        show_message "Searching for '$search_term'..." forever &
        loading_pid=$!

        # Use cache for search
        echo "Using cache file for search" >> "$DIR/log/launch.log"
        grep -i "$search_term" "$CACHE_FILE" > "$paths_file"

        # Generate display names from paths
        if [ -s "$paths_file" ]; then
            while IFS= read -r file; do
                parent_dir=$(dirname "$file")
                emu=$(echo "$parent_dir" | sed -n 's/.*(\([^)]*\)).*/\1/p')
                clean_name=$(clean_rom_name "$file")
                echo "$clean_name ($emu):$file" >> "$results_file"
            done < "$paths_file"

            # Sort by clean name
            sort -t: -k1 "$results_file" -o "$results_file"

            # Split display names and paths
            cut -d: -f1 "$results_file" > "$results_file.display"
            cut -d: -f2 "$results_file" > "$paths_file.sorted"
            mv "$results_file.display" "$results_file"
            mv "$paths_file.sorted" "$paths_file"

            echo "Found $(wc -l < "$results_file") results" >> "$DIR/log/launch.log"

            # Kill loading message
            kill $loading_pid 2>/dev/null

            show_results_screen "$search_term" "$results_file" "$paths_file"
        else
            # Kill loading message
            kill $loading_pid 2>/dev/null

            echo "No results found" >> "$DIR/log/launch.log"
            show_message "No results found, try again!" 2
            search_screen "$search_term"
            return $?
        fi

        # Kill loading message
        kill $loading_pid 2>/dev/null

        show_results_screen "$search_term" "$results_file" "$paths_file"
        result=$?

        if [ "$result" -eq 1 ]; then
            # B button pressed, return to keyboard with same term
            search_screen "$search_term"
            return $?
        elif [ "$result" -eq 2 ]; then
            # No results found
            search_screen "$search_term"
            return $?
        fi
    fi

    return 2  # Return to search if empty search
}

build_cache() {
    echo "Checking cache..." >> "$DIR/log/launch.log"
    mkdir -p "$CACHE_DIR"
    
    # Only rebuild if cache isn't ready
    if [ ! -f "$CACHE_READY" ]; then
        echo "Building cache..." >> "$DIR/log/launch.log"
        
        # Process each console directory
        for console_dir in "$SDCARD_PATH/Roms"/*; do
            if [ -d "$console_dir" ] && \
               [[ ! "$console_dir" =~ "PORTS" ]] && \
               [[ ! "$console_dir" =~ ".disabled" ]]; then
                # List files directly in the console directory
                ls -1 "$console_dir"/*.* 2>/dev/null >> "$CACHE_FILE"
            fi
        done
        
        echo "Cache build complete" >> "$DIR/log/launch.log"
        touch "$CACHE_READY"
    else
        echo "Using existing cache" >> "$DIR/log/launch.log"
    fi
}

# Main loop
{
    # Start cache building in background at startup
    build_cache &

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
