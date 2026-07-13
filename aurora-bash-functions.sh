# Aurora Bash-Funktionen
# In ~/.bashrc einfügen (ab Zeile 33, nach PATH-Definitionen)

# Alte Definitionen sicher entfernen
unalias ask 2>/dev/null
unset -f ask 2>/dev/null
unset -f act 2>/dev/null

# Exit-Code des letzten User-Befehls tracken (bevor Funktionen ihn überschreiben)
__last_exit=0
PROMPT_COMMAND='__last_exit=$?;'"${PROMPT_COMMAND}"

# Hilfsfunktion für den Kontext (OS, User, Pfad, Git, Dateien, Exit-Code)
function _get_ai_context() {
    local os_name="Linux"
    [ -f /etc/os-release ] && os_name=$(grep ^PRETTY_NAME= /etc/os-release | cut -d= -f2 | tr -d '"')

    local git_info=""
    if git rev-parse --is-inside-work-tree &>/dev/null; then
        local branch=$(git branch --show-current 2>/dev/null)
        local dirty=$(git diff --quiet 2>/dev/null && echo "" || echo " *dirty*")
        git_info=" | Git: $branch$dirty"
    fi

    local dir_listing=$(ls -1 | head -15 | tr '\n' ', ')

    echo "[System: $os_name | User: $USER | Path: $PWD$git_info | Files: $dir_listing| Last exit: $__last_exit]"
}

# 1. DER DENKER: 'ask'
# Analysiert, erklärt, recherchiert. Nutzt safe Tools (lesen, web).
function ask() {
    local session_flag=""
    local role="-r aurora-safe"

    if [[ "$1" == "-s" ]]; then
        session_flag="-s $2"; shift 2
    fi

    local context="$(_get_ai_context)"

    if [ -t 0 ]; then
        echo -e "$context\nTask: $*" | aichat $session_flag $role
    else
        (echo -e "$context\nTask: $*\n\n--- INPUT DATA START ---"; cat; echo -e "\n--- INPUT DATA END ---") | aichat $session_flag $role
    fi
}

# 2. DER MACHER: 'act'
# Generiert Befehle und bietet Execute/Copy Menü an. Nutzt alle Tools.
function act() {
    local context="$(_get_ai_context)"
    aichat -e -r aurora-all "$context\nTask: $*"
}

# 3. DER ENTWICKLER: 'code'
# Smart-Version: Terminal = Markdown, Pipe = nur Code.
function code() {
    local session_flag=""
    if [[ "$1" == "-s" ]]; then
        session_flag="-s $2"; shift 2
    fi

    local context="[Project Path: $PWD]"
    local model="local:qwen3.5:9b"
    local prompt="$context\nTask: $*"
    local input=""

    [ ! -t 0 ] && input="\n\n--- CODE SNIPPET ---\n$(cat)\n--- END SNIPPET ---"

    if [ -t 1 ]; then
        echo -e "$prompt$input" | aichat -m "$model" -c $session_flag
    else
        echo -e "$prompt$input" | aichat -m "$model" -c $session_flag | sed -n '/^```/,/^```/ { /^```/d; p; }'
    fi
}
