# ~/.config/fish/functions/create_tag_message.fish

function create_tag_message --description "Generates a Git tag message with recent commits, detecting previous tag/target if needed"
    # Check if we are in a git repository
    if not git rev-parse --is-inside-work-tree > /dev/null 2>&1
        echo "Error: Not inside a git repository." >&2
        return 1
    end

    # --- Argument Parsing and Detection ---
    set -l new_tag
    set -l previous_tag
    set -l target_ref
    set -l print_usage false

    switch (count $argv)
        case 1
            # Only new_tag provided
            set new_tag $argv[1]
            # Detect previous tag
            set -l detected_previous_tag (git describe --tags --abbrev=0 HEAD 2> /dev/null)
            if test $status -ne 0
                echo "Error: Could not automatically detect the previous tag. No tags found reachable from HEAD?" >&2
                echo "Usage: create_tag_message <new_tag> [previous_tag] [target_branch_or_commit]" >&2
                return 1
            end
            set previous_tag $detected_previous_tag
            echo "Detected previous tag: $previous_tag" >&2 # Inform user

            # Default target_ref to HEAD
            set target_ref HEAD
            echo "Using target: HEAD" >&2 # Inform user

        case 2
            # new_tag and previous_tag provided
            set new_tag $argv[1]
            set previous_tag $argv[2]
            # Default target_ref to HEAD
            set target_ref HEAD
            echo "Using target: HEAD" >&2 # Inform user

        case 3
            # All arguments provided
            set new_tag $argv[1]
            set previous_tag $argv[2]
            set target_ref $argv[3]

        case '*' # Handles 0 or more than 3 arguments
            set print_usage true
    end

    if $print_usage
        echo "Usage: create_tag_message <new_tag> [previous_tag] [target_branch_or_commit]" >&2
        echo " - If 'previous_tag' is omitted, the latest tag reachable from HEAD is used." >&2
        echo " - If 'target_branch_or_commit' is omitted, HEAD is used." >&2
        echo "Example (auto-detect): create_tag_message v0.6.0" >&2
        echo "Example (specify prev): create_tag_message v0.6.0 v0.5.1" >&2
        echo "Example (specify all): create_tag_message v0.6.0 v0.5.1 main" >&2
        return 1
    end
    # --- End Argument Parsing ---

    # --- Generate Log ---
    # Use 'set -l log_output' to capture output and check status
    # Use --no-merges by default as in the original example
    set -l log_output (git log "$previous_tag...$target_ref" --oneline --no-merges)
    set -l git_log_status $status

    # Check if the git log command failed (e.g., invalid tag/ref)
    if test $git_log_status -ne 0
        echo "Error: 'git log $previous_tag...$target_ref' failed." >&2
        echo "Check if '$previous_tag' and '$target_ref' exist and the range is valid." >&2
        # Optionally show the specific git error by re-running without capturing output
        # git log "$previous_tag...$target_ref" --oneline --no-merges >&2
        return 1
    end

    # Check if log output is empty (can happen if previous_tag == target_ref)
    if test -z "$log_output"
       echo "Warning: No commits found between '$previous_tag' and '$target_ref'." >&2
       # Decide if you want to proceed or exit here. We'll proceed but the message will be minimal.
    end

    # --- Construct and Print Message ---
    printf "Latest release: %s\n\n%s\n" $new_tag $log_output

    # Success
    return 0
end
