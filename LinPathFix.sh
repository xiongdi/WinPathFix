#!/usr/bin/env bash
#
# LinPathFix - Hierarchical Priority-Based Path Repair for Linux (Manager vs Installed Apps).
#

set -e

BACKUP_ONLY=0
DRY_RUN=0
NON_INTERACTIVE=0

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --backup-only) BACKUP_ONLY=1 ;;
        --dry-run) DRY_RUN=1 ;;
        --non-interactive) NON_INTERACTIVE=1 ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

# Colors
CYAN='\033[0;36m'
GREEN='\033[0;32m'
GRAY='\033[0;90m'
WHITE='\033[0;37m'
DARK_GRAY='\033[1;30m'
DARK_RED='\033[0;31m'
DARK_YELLOW='\033[0;33m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Data Structures (using associative arrays in bash 4+)
declare -A DISCOVERY_MANAGER
declare -A DISCOVERY_APPS
declare -A COMMANDS=(
    ["Homebrew"]="brew"
    ["Nix"]="nix"
    ["Apt"]="apt"
    ["Dnf"]="dnf"
    ["Yum"]="yum"
    ["Zypper"]="zypper"
    ["Pacman"]="pacman"
    ["Apk"]="apk"
    ["Asdf"]="asdf"
    ["Mise"]="mise"
    ["Npm"]="npm"
    ["Yarn"]="yarn"
    ["Pnpm"]="pnpm"
    ["Bun"]="bun"
    ["Deno"]="deno"
    ["Fnm"]="fnm"
    ["Volta"]="volta"
    ["Pip"]="pip"
    ["Pip3"]="pip3"
    ["Pipx"]="pipx"
    ["Conda"]="conda"
    ["Poetry"]="poetry"
    ["Pyenv"]="pyenv"
    ["Uv"]="uv"
    ["Cargo"]="cargo"
    ["Go"]="go"
    ["dotnet"]="dotnet"
    ["Sdkman"]="sdk"
    ["Rbenv"]="rbenv"
    ["Rvm"]="rvm"
    ["Gem"]="gem"
    ["Composer"]="composer"
    ["Vcpkg"]="vcpkg"
    ["Conan"]="conan"
    ["Luarocks"]="luarocks"
    ["Opam"]="opam"
    ["Mix"]="mix"
    ["Ghcup"]="ghcup"
    ["Pub"]="pub"
    ["Gcloud"]="gcloud"
    ["JetBrains"]="jetbrains-toolbox"
    ["Guix"]="guix"
    ["Snap"]="snap"
    ["Flatpak"]="flatpak"
)
ORDER=("Homebrew" "Nix" "Guix" "Apt" "Dnf" "Yum" "Zypper" "Pacman" "Apk" "Asdf" "Mise" "Npm" "Yarn" "Pnpm" "Bun" "Deno" "Fnm" "Volta" "Pip" "Pip3" "Pipx" "Conda" "Poetry" "Pyenv" "Uv" "Cargo" "Go" "dotnet" "Sdkman" "Rbenv" "Rvm" "Gem" "Composer" "Vcpkg" "Conan" "Luarocks" "Opam" "Mix" "Ghcup" "Pub" "Gcloud" "JetBrains" "Snap" "Flatpak")

# --- Helpers ---

add_path() {
    local name="$1"
    local ptype="$2"
    local p="$3"
    
    if [ -d "$p" ]; then
        # Remove trailing slash
        p="${p%/}"
        if [ "$ptype" == "Manager" ]; then
            if [[ ! " ${DISCOVERY_MANAGER[$name]} " =~ " ${p} " ]]; then
                DISCOVERY_MANAGER[$name]="${DISCOVERY_MANAGER[$name]} $p"
            fi
        elif [ "$ptype" == "Apps" ]; then
            if [[ ! " ${DISCOVERY_APPS[$name]} " =~ " ${p} " ]]; then
                DISCOVERY_APPS[$name]="${DISCOVERY_APPS[$name]} $p"
            fi
        fi
        echo "$p"
    fi
}

backup_profile() {
    local profile="$1"
    if [ -f "$profile" ]; then
        local date_str=$(date +"%Y%m%d_%H%M%S")
        local backup_file="${profile}.bak_${date_str}"
        cp "$profile" "$backup_file"
        echo -e "${GREEN}[+] Backup created: $backup_file${NC}"
    fi
}

# --- Path Discovery ---

get_ordered_target_paths() {
    local all_paths=""
    
    # 1. Check if commands are already in PATH
    for name in "${ORDER[@]}"; do
        local cmd="${COMMANDS[$name]}"
        if command -v "$cmd" &> /dev/null; then
            local cmd_path=$(command -v "$cmd")
            local cmd_dir=$(dirname "$cmd_path")
            local res=$(add_path "$name" "Manager" "$cmd_dir")
            if [ -n "$res" ]; then all_paths="$all_paths $res"; fi
        fi
    done

    # 2. Add well-known paths
    
    # Homebrew
    local brew_paths=("/home/linuxbrew/.linuxbrew/bin" "/home/linuxbrew/.linuxbrew/sbin" "/opt/homebrew/bin" "/opt/homebrew/sbin")
    for bp in "${brew_paths[@]}"; do
        local res=$(add_path "Homebrew" "Manager" "$bp")
        if [ -n "$res" ]; then all_paths="$all_paths $res"; fi
    done

    # Nix
    local nix_paths=("$HOME/.nix-profile/bin" "/nix/var/nix/profiles/default/bin")
    for np in "${nix_paths[@]}"; do
        local res=$(add_path "Nix" "Apps" "$np")
        if [ -n "$res" ]; then all_paths="$all_paths $res"; fi
    done

    # Asdf
    local asdf_shims="$HOME/.asdf/shims"
    local res=$(add_path "Asdf" "Manager" "$asdf_shims")
    if [ -n "$res" ]; then all_paths="$all_paths $res"; fi

    # Mise
    local mise_shims=("$HOME/.local/share/mise/shims" "$HOME/.mise/shims")
    for ms in "${mise_shims[@]}"; do
        local res=$(add_path "Mise" "Manager" "$ms")
        if [ -n "$res" ]; then all_paths="$all_paths $res"; fi
    done

    # Npm
    local npm_global="$HOME/.npm-global/bin"
    local res=$(add_path "Npm" "Apps" "$npm_global")
    if [ -n "$res" ]; then all_paths="$all_paths $res"; fi
    
    # Try getting prefix via npm
    if command -v npm &> /dev/null; then
        local npm_prefix=$(npm config get prefix 2>/dev/null)
        if [ -n "$npm_prefix" ] && [ -d "$npm_prefix/bin" ]; then
            local res=$(add_path "Npm" "Apps" "$npm_prefix/bin")
            if [ -n "$res" ]; then all_paths="$all_paths $res"; fi
        fi
    fi

    # Yarn
    local yarn_global="$HOME/.yarn/bin"
    local res=$(add_path "Yarn" "Apps" "$yarn_global")
    if [ -n "$res" ]; then all_paths="$all_paths $res"; fi

    # Pnpm
    local pnpm_home="${PNPM_HOME:-$HOME/.local/share/pnpm}"
    local res=$(add_path "Pnpm" "Apps" "$pnpm_home")
    if [ -n "$res" ]; then all_paths="$all_paths $res"; fi

    # Bun
    local bun_bin="$HOME/.bun/bin"
    local res=$(add_path "Bun" "Apps" "$bun_bin")
    if [ -n "$res" ]; then all_paths="$all_paths $res"; fi

    # Deno
    local deno_bin="$HOME/.deno/bin"
    local res=$(add_path "Deno" "Apps" "$deno_bin")
    if [ -n "$res" ]; then all_paths="$all_paths $res"; fi

    # Fnm
    local fnm_dir="${XDG_DATA_HOME:-$HOME/.local/share}/fnm"
    local res=$(add_path "Fnm" "Manager" "$fnm_dir")
    if [ -n "$res" ]; then all_paths="$all_paths $res"; fi

    # Volta
    local volta_bin="$HOME/.volta/bin"
    local res=$(add_path "Volta" "Apps" "$volta_bin")
    if [ -n "$res" ]; then all_paths="$all_paths $res"; fi

    # Pip
    local py_user_base="$HOME/.local/bin"
    local res=$(add_path "Pip" "Apps" "$py_user_base")
    if [ -n "$res" ]; then all_paths="$all_paths $res"; fi

    # Pipx
    local pipx_bin="$HOME/.local/bin"
    local res=$(add_path "Pipx" "Apps" "$pipx_bin")
    if [ -n "$res" ]; then all_paths="$all_paths $res"; fi

    # Conda
    local conda_paths=("$HOME/miniconda3/bin" "$HOME/anaconda3/bin" "/opt/miniconda3/bin" "/opt/anaconda3/bin")
    for cp in "${conda_paths[@]}"; do
        local res=$(add_path "Conda" "Manager" "$cp")
        if [ -n "$res" ]; then all_paths="$all_paths $res"; fi
    done

    # Poetry
    local poetry_bin="$HOME/.local/bin"
    local res=$(add_path "Poetry" "Apps" "$poetry_bin")
    if [ -n "$res" ]; then all_paths="$all_paths $res"; fi

    # Pyenv
    local pyenv_shims="$HOME/.pyenv/shims"
    local res=$(add_path "Pyenv" "Manager" "$pyenv_shims")
    if [ -n "$res" ]; then all_paths="$all_paths $res"; fi

    # Uv
    local uv_bin="$HOME/.cargo/bin" # uv commonly installs here or ~/.local/bin
    local res=$(add_path "Uv" "Apps" "$uv_bin")
    if [ -n "$res" ]; then all_paths="$all_paths $res"; fi

    # Cargo
    local cargo_bin="$HOME/.cargo/bin"
    local res=$(add_path "Cargo" "Manager" "$cargo_bin")
    if [ -n "$res" ]; then all_paths="$all_paths $res"; fi

    # Go
    local go_user_bin="$HOME/go/bin"
    local res=$(add_path "Go" "Apps" "$go_user_bin")
    if [ -n "$res" ]; then all_paths="$all_paths $res"; fi
    local go_sys_bin="/usr/local/go/bin"
    local res=$(add_path "Go" "Manager" "$go_sys_bin")
    if [ -n "$res" ]; then all_paths="$all_paths $res"; fi

    # .NET
    local dotnet_tools="$HOME/.dotnet/tools"
    local res=$(add_path "dotnet" "Apps" "$dotnet_tools")
    if [ -n "$res" ]; then all_paths="$all_paths $res"; fi

    # Sdkman
    local sdkman_bin="$HOME/.sdkman/bin"
    local res=$(add_path "Sdkman" "Manager" "$sdkman_bin")
    if [ -n "$res" ]; then all_paths="$all_paths $res"; fi

    # Rbenv
    local rbenv_bin="$HOME/.rbenv/bin"
    local res=$(add_path "Rbenv" "Manager" "$rbenv_bin")
    if [ -n "$res" ]; then all_paths="$all_paths $res"; fi

    # Rvm
    local rvm_bin="$HOME/.rvm/bin"
    local res=$(add_path "Rvm" "Manager" "$rvm_bin")
    if [ -n "$res" ]; then all_paths="$all_paths $res"; fi

    # Gem
    local gem_home="${GEM_HOME:-$HOME/.gem/ruby/*/bin}"
    for gh in $gem_home; do
        if [ -d "$gh" ]; then
            local res=$(add_path "Gem" "Apps" "$gh")
            if [ -n "$res" ]; then all_paths="$all_paths $res"; fi
        fi
    done

    # Composer
    local composer_bin="$HOME/.config/composer/vendor/bin"
    local res=$(add_path "Composer" "Apps" "$composer_bin")
    if [ -n "$res" ]; then all_paths="$all_paths $res"; fi

    # Vcpkg
    local vcpkg_paths=("$VCPKG_ROOT" "$HOME/vcpkg" "/opt/vcpkg")
    for vp in "${vcpkg_paths[@]}"; do
        if [ -n "$vp" ]; then
            local res=$(add_path "Vcpkg" "Manager" "$vp")
            if [ -n "$res" ]; then all_paths="$all_paths $res"; fi
        fi
    done

    # Conan
    local conan_bin="$HOME/.conan2/profiles/default/bin"
    local res=$(add_path "Conan" "Apps" "$conan_bin")
    if [ -n "$res" ]; then all_paths="$all_paths $res"; fi

    # Luarocks
    local luarocks_bin="$HOME/.luarocks/bin"
    local res=$(add_path "Luarocks" "Apps" "$luarocks_bin")
    if [ -n "$res" ]; then all_paths="$all_paths $res"; fi

    # Opam
    local opam_bin="$HOME/.opam/default/bin"
    local res=$(add_path "Opam" "Apps" "$opam_bin")
    if [ -n "$res" ]; then all_paths="$all_paths $res"; fi

    # Mix
    local mix_bin="$HOME/.mix/escripts"
    local res=$(add_path "Mix" "Apps" "$mix_bin")
    if [ -n "$res" ]; then all_paths="$all_paths $res"; fi

    # Ghcup
    local ghcup_bin="$HOME/.ghcup/bin"
    local res=$(add_path "Ghcup" "Manager" "$ghcup_bin")
    if [ -n "$res" ]; then all_paths="$all_paths $res"; fi
    local cabal_bin="$HOME/.cabal/bin"
    local res=$(add_path "Ghcup" "Apps" "$cabal_bin")
    if [ -n "$res" ]; then all_paths="$all_paths $res"; fi

    # Pub
    local pub_bin="$HOME/.pub-cache/bin"
    local res=$(add_path "Pub" "Apps" "$pub_bin")
    if [ -n "$res" ]; then all_paths="$all_paths $res"; fi

    # Gcloud
    local gcloud_bin="$HOME/google-cloud-sdk/bin"
    local res=$(add_path "Gcloud" "Manager" "$gcloud_bin")
    if [ -n "$res" ]; then all_paths="$all_paths $res"; fi

    # JetBrains
    local jb_scripts="${XDG_DATA_HOME:-$HOME/.local/share}/JetBrains/Toolbox/scripts"
    local res=$(add_path "JetBrains" "Apps" "$jb_scripts")
    if [ -n "$res" ]; then all_paths="$all_paths $res"; fi

    # Guix
    local guix_bin="$HOME/.guix-profile/bin"
    local res=$(add_path "Guix" "Apps" "$guix_bin")
    if [ -n "$res" ]; then all_paths="$all_paths $res"; fi

    # Snap
    local snap_bin="/snap/bin"
    local res=$(add_path "Snap" "Manager" "$snap_bin")
    if [ -n "$res" ]; then all_paths="$all_paths $res"; fi

    # Flatpak
    local flatpak_sys_bin="/var/lib/flatpak/exports/bin"
    local res=$(add_path "Flatpak" "Apps" "$flatpak_sys_bin")
    if [ -n "$res" ]; then all_paths="$all_paths $res"; fi
    local flatpak_user_bin="$HOME/.local/share/flatpak/exports/bin"
    local res=$(add_path "Flatpak" "Apps" "$flatpak_user_bin")
    if [ -n "$res" ]; then all_paths="$all_paths $res"; fi

    # Return unique paths separated by colon
    echo "$all_paths" | tr ' ' '\n' | awk 'NF' | awk '!seen[$0]++' | paste -sd ":" -
}

# --- Reporting ---

show_repair_report() {
    echo -e "\n${CYAN}================================================================================${NC}"
    echo -e "${CYAN}                 LINPATHFIX: HIERARCHICAL REPAIR REPORT                 ${NC}"
    echo -e "${CYAN}================================================================================${NC}"
    
    local stats_found=0
    local stats_missing=0
    local stats_packages=0

    for name in "${ORDER[@]}"; do
        local cmd="${COMMANDS[$name]}"
        local found=0
        if command -v "$cmd" &> /dev/null; then found=1; fi
        
        # 1. Manager Status
        if [ $found -eq 1 ]; then
            echo -ne "  ${GREEN}[v] ${NC}"
            stats_found=$((stats_found + 1))
        else
            echo -ne "  ${GRAY}[x] ${NC}"
            stats_missing=$((stats_missing + 1))
        fi
        printf "${WHITE}%-12s${NC}" "$name"
        
        # 2. Manager Path
        local manager_exe=""
        if [ $found -eq 1 ]; then
            manager_exe=$(command -v "$cmd")
        else
            if [ -n "${DISCOVERY_MANAGER[$name]}" ]; then
                for dir in ${DISCOVERY_MANAGER[$name]}; do
                    if [ -x "$dir/$cmd" ]; then
                        manager_exe="$dir/$cmd"
                        break
                    fi
                done
            fi
        fi

        if [ -n "$manager_exe" ]; then
            echo -e " -> ${DARK_GRAY}$manager_exe${NC}"
        else
            echo -e " -> ${DARK_RED}(Not Found)${NC}"
        fi

        # 3. Packages (Simplified for bash, counts mainly)
        if [ $found -eq 1 ]; then
            local pkg_count=0
            local pkg_list=""
            
            case "$name" in
                "Homebrew")
                    pkg_count=$(brew list -1 2>/dev/null | wc -l)
                    ;;
                "Nix")
                    pkg_count=$(nix-env -q 2>/dev/null | wc -l)
                    ;;
                "Apt")
                    pkg_count=$(dpkg-query -f '.\n' -W 2>/dev/null | wc -l)
                    ;;
                "Pacman")
                    pkg_count=$(pacman -Q 2>/dev/null | wc -l)
                    ;;
                "Apk")
                    pkg_count=$(apk info 2>/dev/null | wc -l)
                    ;;
                "Dnf"|"Yum"|"Zypper")
                    pkg_count=$(rpm -qa 2>/dev/null | wc -l)
                    ;;
                "Asdf")
                    pkg_count=$(asdf list 2>/dev/null | grep -v 'No versions installed' | wc -l)
                    ;;
                "Mise")
                    pkg_count=$(mise ls 2>/dev/null | wc -l)
                    ;;
                "Npm")
                    pkg_count=$(npm ls -g --depth=0 --parseable 2>/dev/null | tail -n +2 | wc -l)
                    ;;
                "Yarn")
                    pkg_count=$(yarn global list --depth=0 2>/dev/null | grep -E 'info "[^"]+"' | wc -l)
                    ;;
                "Pnpm")
                    pkg_count=$(pnpm ls -g --depth=0 2>/dev/null | tail -n +2 | wc -l)
                    ;;
                "Bun")
                    pkg_count=$(bun pm ls --global 2>/dev/null | tail -n +2 | wc -l)
                    ;;
                "Deno")
                    pkg_count=$(ls -1 $HOME/.deno/bin 2>/dev/null | wc -l)
                    ;;
                "Fnm")
                    pkg_count=$(fnm ls 2>/dev/null | tail -n +2 | wc -l)
                    ;;
                "Volta")
                    pkg_count=$(volta list all --format plain 2>/dev/null | wc -l)
                    ;;
                "Pip"|"Pip3")
                    pkg_count=$(pip list --format=columns 2>/dev/null | tail -n +3 | wc -l)
                    ;;
                "Pipx")
                    pkg_count=$(pipx list --short 2>/dev/null | wc -l)
                    ;;
                "Conda")
                    pkg_count=$(conda list 2>/dev/null | tail -n +4 | wc -l)
                    ;;
                "Poetry")
                    pkg_count=0 # Poetry is project based
                    ;;
                "Pyenv")
                    pkg_count=$(pyenv versions --bare 2>/dev/null | wc -l)
                    ;;
                "Uv")
                    pkg_count=$(uv tool list 2>/dev/null | wc -l)
                    ;;
                "Cargo")
                    pkg_count=$(cargo install --list 2>/dev/null | grep -E '^[a-zA-Z0-9_-]+ v' | wc -l)
                    ;;
                "Sdkman")
                    pkg_count=$(sdk list installed 2>/dev/null | grep -E '^\s+\*' | wc -l)
                    ;;
                "Rbenv")
                    pkg_count=$(rbenv versions --bare 2>/dev/null | wc -l)
                    ;;
                "Rvm")
                    pkg_count=$(rvm list 2>/dev/null | grep -E '^(=\*|\*|=|\s+ruby-)' | wc -l)
                    ;;
                "Gem")
                    pkg_count=$(gem list --local 2>/dev/null | wc -l)
                    ;;
                "Composer")
                    pkg_count=$(composer global show -i --name-only 2>/dev/null | wc -l)
                    ;;
                "Vcpkg")
                    pkg_count=$(vcpkg list 2>/dev/null | wc -l)
                    ;;
                "Conan")
                    pkg_count=$(conan list "*" 2>/dev/null | tail -n +2 | wc -l)
                    ;;
                "Luarocks")
                    pkg_count=$(luarocks list --porcelain 2>/dev/null | wc -l)
                    ;;
                "Opam")
                    pkg_count=$(opam list -s 2>/dev/null | wc -l)
                    ;;
                "Mix")
                    pkg_count=$(mix archive 2>/dev/null | grep -E '^\*\s' | wc -l)
                    ;;
                "Ghcup")
                    pkg_count=$(ghcup list -c installed 2>/dev/null | wc -l)
                    ;;
                "Pub")
                    pkg_count=$(dart pub global list 2>/dev/null | grep -v 'Installed' | wc -l)
                    ;;
                "Gcloud")
                    pkg_count=$(gcloud components list --only-local-state 2>/dev/null | grep 'Installed' | wc -l)
                    ;;
                "JetBrains")
                    pkg_count=$(ls -1 "${XDG_DATA_HOME:-$HOME/.local/share}/JetBrains/Toolbox/scripts" 2>/dev/null | wc -l)
                    ;;
                "Guix")
                    pkg_count=$(guix package -I 2>/dev/null | wc -l)
                    ;;
                "Snap")
                    pkg_count=$(snap list 2>/dev/null | tail -n +2 | wc -l)
                    ;;
                "Flatpak")
                    pkg_count=$(flatpak list --app 2>/dev/null | wc -l)
                    ;;
                "dotnet")
                    pkg_count=$(dotnet tool list -g 2>/dev/null | tail -n +3 | wc -l)
                    ;;
            esac
            
            if [ "$pkg_count" -gt 0 ]; then
                stats_packages=$((stats_packages + pkg_count))
                echo -e "      ${DARK_YELLOW}[Packages: $pkg_count]${NC}"
            fi
        fi
    done
    
    echo -e "${CYAN}--------------------------------------------------------------------------------${NC}"
    echo -e "${CYAN} SUMMARY${NC}"
    echo -e "${CYAN}  Managers Found:   ${GREEN}$stats_found${NC}"
    echo -e "${CYAN}  Managers Missing: ${GRAY}$stats_missing${NC}"
    echo -e "${CYAN}  Total Packages:   ${YELLOW}$stats_packages${NC}"
    echo -e "${CYAN}--------------------------------------------------------------------------------${NC}"
    echo -e "${GRAY}[i] All high-priority tool paths moved to the START of your PATH.${NC}"
    local order_str=$(printf " > %s" "${ORDER[@]}")
    order_str=${order_str:3}
    echo -e "${DARK_GRAY}[i] Tool Path Order: $order_str${NC}"
    echo -e "${CYAN}================================================================================${NC}"
}

# --- Profile Management ---

update_profile() {
    local profile="$1"
    local new_paths="$2"
    
    if [ ! -f "$profile" ]; then return; fi
    
    if [ $DRY_RUN -eq 1 ]; then
        echo -e "${YELLOW}[DryRun] Would update $profile${NC}"
        return
    fi
    
    local block_start="# --- LinPathFix Start ---"
    local block_end="# --- LinPathFix End ---"
    local export_line="export PATH=\"$new_paths:\$PATH\""
    
    # Check if block exists
    if grep -qF "$block_start" "$profile"; then
        # Replace existing block
        sed -i.bak "/$block_start/,/$block_end/c\\
$block_start\\
$export_line\\
$block_end" "$profile"
        rm -f "${profile}.bak"
    else
        # Append new block
        echo "" >> "$profile"
        echo "$block_start" >> "$profile"
        echo "$export_line" >> "$profile"
        echo "$block_end" >> "$profile"
    fi
    echo -e "${GREEN}[*] Updated $profile${NC}"
}

# --- Main ---

clear
cat << "EOF"
  _      _       ___       _   _     _____ _      
 | |    (_)     |  _ \     | | | |   |  ___(_)     
 | |     _ _ __ | |_) |__ _| |_| |__ | |_   ___  __
 | |    | | '_ \|  __/ _` | __| '_ \|  _| | \ \/ /
 | |____| | | | | | | | (_| | |_| | | | |   | |>  < 
 |______|_|_| |_|_|  \__,_|\__|_| |_|_|   |_/_/\_\
                                                     
     Linux PATH Repair & Optimization Utility
EOF
echo -e "${CYAN}\nInitializing Hierarchical Discovery...${NC}"

# 1. Discovery
target_path_str=$(get_ordered_target_paths)

# 2. Backup
echo -ne "${GRAY}[*] Creating safety backups...${NC}"
echo ""
PROFILES=("$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile")
for p in "${PROFILES[@]}"; do
    if [ -f "$p" ]; then
        backup_profile "$p"
    fi
done
echo -e " ${GREEN}Done.${NC}"

# 3. Apply Fix
if [ $BACKUP_ONLY -eq 0 ]; then
    echo -e "${GRAY}[*] Analyzing and prioritizing environment variables...${NC}"
    for p in "${PROFILES[@]}"; do
        update_profile "$p" "$target_path_str"
    done
fi

# 4. Report
show_repair_report

echo -e "\n${YELLOW}[!] IMPORTANT: PATH changes have been saved to your shell profiles.${NC}"
echo -e "${YELLOW}[!] You MUST RESTART your terminal or run 'source ~/.bashrc' (or equivalent) for changes to take effect.${NC}"

if [ $NON_INTERACTIVE -eq 0 ]; then
    echo -e "\nPress any key to exit..."
    read -n 1 -s -r
fi
