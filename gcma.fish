# ~/.config/fish/functions/gcma.fish

function gcma --description "Generate Conventional Commit message using llm for Git or Jujutsu (jj)"
    # --- Configuration ---
    set -l default_model "gemini-2.5-pro-exp-03-25" # <--- CHANGE THIS

    # --- Argument Parsing ---
    # Add t/tool flag for explicit selection
    argparse --name gcma 'h/help' 'm/model=' 'c/commit' 'e/edit' 't/tool=' -- $argv
    or return 1

    # Validate --tool flag value if provided
    if set -q _flag_tool
        if test "$_flag_tool" != "git"; and test "$_flag_tool" != "jj"
            echo "Error: Invalid value for --tool. Must be 'git' or 'jj'." >&2
            return 1
        end
    end

    # Handle help flag
    if set -q _flag_help
        echo "Usage: gcma [--tool git|jj] [-m MODEL] [-c | -e]"
        echo "  Generates a multi-line Conventional Commit message using llm."
        echo "  Operates on Git staged changes or Jujutsu (jj) working copy changes."
        echo
        echo "Tool Selection (when both Git and jj are detected):"
        echo "  --tool git     Force using Git (git diff --staged, git commit)"
        echo "  --tool jj      Force using Jujutsu (jj diff, jj commit/describe)"
        echo "  (default)      Uses Jujutsu (jj) if available, otherwise Git."
        echo
        echo "Options:"
        echo "  -m, --model MODEL  Specify the language model to use (default: '$default_model')"
        echo "  -c, --commit       Commit directly with the generated message."
        echo "                     (Runs 'git commit' or 'jj commit')"
        echo "  -e, --edit         Open message in editor before committing/describing."
        echo "                     (Runs 'git commit -e' or 'jj describe -F <tempfile>')"
        echo "  -h, --help         Show this help message"
        return 0
    end

    # Ensure -c and -e are not used together
    if set -q _flag_commit; and set -q _flag_edit
        echo "Error: Cannot use --commit (-c) and --edit (-e) flags together." >&2
        return 1
    end

    # --- Prerequisites Check ---
    if not command -q llm
        echo "Error: llm command not found. Install with: pip install llm" >&2
        return 1
    end

    # --- Detect Repository Tools ---
    set -l has_jj false
    set -l has_git false
    if command -q jj; and jj root > /dev/null 2>&1
        set has_jj true
    end
    if command -q git; and git rev-parse --is-inside-work-tree > /dev/null 2>&1
        set has_git true
    end

    # --- Determine Effective Tool ---
    set -l repo_type "none"
    if set -q _flag_tool
        if test "$_flag_tool" = "jj"
            if $has_jj
                set repo_type "jj"
            else
                echo "Error: --tool jj specified, but not in a jj repository." >&2
                return 1
            end
        else if test "$_flag_tool" = "git"
            if $has_git
                set repo_type "git"
            else
                echo "Error: --tool git specified, but not in a git repository." >&2
                return 1
            end
        end
    else
        # Default logic: Prioritize jj if available
        if $has_jj
            set repo_type "jj"
        else if $has_git
            set repo_type "git"
        end
    end

    # Check if a repository type was determined
    if test "$repo_type" = "none"
        echo "Error: Not inside a git or jj repository." >&2
        return 1
    end

    # --- Set up Tool-Specific Commands ---
    set -l check_cmd ""
    set -l diff_cmd ""
    # Note: Commit/Edit commands are now handled directly later, not via eval strings
    set -l check_fail_msg ""
    set -l tmpfile "" # Define outside the block for cleanup trap

    if test "$repo_type" = "jj"
        echo "-- Using Jujutsu (jj) backend --" >&2
        # Check if there's *any* output from diff --summary
        set check_cmd "test -n \"(jj diff --summary --color=never | string collect)\""
        set diff_cmd "jj diff --color=never"
        # commit_cmd handled later
        # edit_cmd handled later using temp file
        set check_fail_msg "No tracked working copy changes found in jj. Run 'jj status' or 'jj diff'."
        # Setup trap only if we are in jj mode and might create a temp file for editing
        trap "if test -n \"\$tmpfile\"; and test -e \"\$tmpfile\"; rm -f \"\$tmpfile\"; end" EXIT

    else if test "$repo_type" = "git"
        echo "-- Using Git backend --" >&2
        # Check if diff --staged is NOT empty (returns non-zero if empty)
        set check_cmd "not git diff --staged --quiet --exit-code"
        set diff_cmd "git diff --staged"
        # commit_cmd handled later
        # edit_cmd handled later
        set check_fail_msg "No staged Git changes found. Stage files using 'git add' first."
        # No temp file needed for git, so no trap setup/cleanup needed here
    end

    # --- Check for Changes (Using selected tool's command) ---
    # Use 'fish -c' to evaluate the check command string reliably
    if not eval "$check_cmd"
        echo $check_fail_msg >&2
        # Explicitly clear trap if it was set and we are exiting early
        if test "$repo_type" = "jj"; trap - EXIT; end
        return 1
    end

    # --- Prompt Engineering ---
    set -l system_prompt "You are an expert programmer generating Conventional Commit messages."
    set -l system_prompt "$system_prompt Analyze the provided diff (from $repo_type)."
    set -l system_prompt "$system_prompt MANDATORY FORMAT REQUIREMENT: There MUST be an empty line between subject and body."
    set -l system_prompt "$system_prompt Follow this EXACT multi-line format:"
    set -l system_prompt "$system_prompt 1. First line: Subject in Conventional Commit format (e.g., 'feat(scope): description'). Under 72 chars."
    set -l system_prompt "$system_prompt 2. Second line: EMPTY LINE WITH NOTHING ON IT."
    set -l system_prompt "$system_prompt 3. Third line onward: Body explaining changes, use '- ' for bullets."
    set -l system_prompt "$system_prompt Bad example (WRONG):\nfeat: Add user auth - Implemented login."
    set -l system_prompt "$system_prompt Good example (CORRECT):\nfeat: Add user auth\n\n- Implemented login.\n- Added hashing."
    set -l system_prompt "$system_prompt CRITICAL: Insert a blank line between subject and body. Do not use '-' in the subject line."

    # --- Build llm Command ---
    set -l model_to_use $default_model
    if set -q _flag_model
        set model_to_use "$_flag_model"
    end
    # No longer need llm_cmd_args list. We'll use the components directly.

    # --- Execute Diff and llm ---
    set -l generated_message ""
    set -l llm_status 0
    set -l diff_output ""

    echo "🔍 Running diff command: $diff_cmd" >&2
    # Capture the diff output into a variable using 'fish -c' for safety
    set diff_output (eval "$diff_cmd" | string collect)
    set diff_status $status

    # Check if the diff command itself failed
    if test $diff_status -ne 0
        echo "❌ Error: Diff command '$diff_cmd' failed with status $diff_status." >&2
        if test -n "$diff_output"; echo "Diff Output:\n$diff_output" >&2; end # Show partial output if any
        if test "$repo_type" = "jj"; trap - EXIT; end # Cleanup trap if set
        return $diff_status
    end

    # Although check_cmd should prevent this, add a safeguard
    if test -z "$diff_output"
        echo "❌ Error: Diff command returned empty output unexpectedly." >&2
        if test "$repo_type" = "jj"; trap - EXIT; end # Cleanup trap if set
        return 1
    end

    echo "⏳ Generating commit message using model '$model_to_use' (via $repo_type)..." >&2

    # Pipe the captured diff_output directly to the llm command
    # Use 'echo -n' to avoid adding an extra newline
    # Call llm directly with arguments instead of using the $llm_cmd_args list variable
    set generated_message (echo -n -- "$diff_output" | llm --system "$system_prompt" --model "$model_to_use")
    echo "✨ llm processing complete." >&2
    echo "📝 Generated message:" >&2
    echo "---" >&2; echo "$generated_message" >&2; echo "---" >&2
    set llm_status $status

    # Check llm command status
    if test $llm_status -ne 0
        # Try to capture stderr from llm if possible (might require temporary file or more complex redirection)
        # For now, just report the status code
        echo "❌ Error: llm command failed with status $llm_status." >&2
        if test "$repo_type" = "jj"; trap - EXIT; end # Cleanup trap if set
        return $llm_status
    end

    # Trim potential markdown code fences or leading/trailing quotes/whitespace
    # set generated_message (string trim --chars '```' -- "$generated_message")


    # Check if llm returned an empty message after trimming
    if test -z "$generated_message"
        echo "❌ Error: llm returned an empty message after processing." >&2
        if test "$repo_type" = "jj"; trap - EXIT; end # Cleanup trap if set
        return 1
    end

    # --- Output or Commit/Edit (Using selected tool's commands) ---
    set -l final_status 0
    if set -q _flag_commit
        echo "✅ Committing with message (via $repo_type):" >&2
        echo "---" >&2; echo "$generated_message" >&2; echo "---" >&2
        if test "$repo_type" = "jj"
            # jj commit creates a NEW commit with the message
            jj commit -m "$generated_message"
            set final_status $status
        else # git
            # git commit applies message to staged changes
            git commit -m "$generated_message"
            set final_status $status
        end
    else if set -q _flag_edit
        echo "✏️ Opening editor with message (via $repo_type):" >&2
        echo "---" >&2; echo "$generated_message" >&2; echo "---" >&2
        if test "$repo_type" = "jj"
            # For jj edit, we modify the description of the CURRENT working copy commit
            set tmpfile (mktemp /tmp/gcma-jj-msg.XXXXXX)
            # Check if mktemp failed
            if test $status -ne 0; or not test -e "$tmpfile"
                echo "❌ Error: Failed to create temporary file for editing." >&2
                set final_status 1
            else
                # Use printf for safer writing, especially with special chars
                printf '%s' "$generated_message" > "$tmpfile"
                # jj describe loads from file AND opens editor
                jj describe -F "$tmpfile"
                set final_status $status
                # Cleanup is handled by the trap
            end
        else # git
            # git commit -e opens editor with the provided message
            git commit -m "$generated_message" -e
            set final_status $status
            # No temp file cleanup needed for git
        end
    else
        # Default action: print the generated message to stdout
        echo "$generated_message"
        set final_status 0
    end

    # Clean up trap explicitly on normal exit (it runs automatically on errors)
    if test "$repo_type" = "jj"; trap - EXIT; end
    # Perform manual cleanup if tmpfile exists (belt-and-suspenders with trap)
    if test -n "$tmpfile"; and test -e "$tmpfile"; rm -f "$tmpfile"; end

    return $final_status
end

# Optional: Save the function
# funcsave gcma
