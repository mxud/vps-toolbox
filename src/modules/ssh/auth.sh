# ============ 修改密码 ============

set_root_password() {
    root_use || return
    echo "设置 root 密码"
    passwd root || return 1
    echo -e "${gl_lv}root 密码设置完毕${gl_bai}；SSH 登录策略未改变。"
}

# ============ SSH 密钥登录 ============

vps_ssh_select_user() {
    local requested="${1:-root}" entry ignored
    [[ "$requested" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] || { echo "用户名无效" >&2; return 1; }
    entry=$(getent passwd "$requested" 2>/dev/null || awk -F: -v name="$requested" '$1 == name {print; exit}' /etc/passwd)
    [ -n "$entry" ] || { echo "用户不存在: $requested" >&2; return 1; }
    IFS=: read -r ignored ignored ignored ignored ignored VPS_SSH_HOME ignored <<< "$entry"
    [ -d "$VPS_SSH_HOME" ] && [[ "$VPS_SSH_HOME" == /* ]] || {
        echo "用户主目录不存在" >&2; return 1
    }
    VPS_SSH_USER="$requested"
    VPS_SSH_UID=$(id -u "$requested") || return 1
    VPS_SSH_GID=$(id -g "$requested") || return 1
    VPS_SSH_AUTH="$VPS_SSH_HOME/.ssh/authorized_keys"
}

vps_ssh_prepare_auth() {
    [ ! -L "$VPS_SSH_HOME/.ssh" ] && [ ! -L "$VPS_SSH_AUTH" ] || {
        echo "拒绝写入符号链接形式的 .ssh 或 authorized_keys" >&2; return 1
    }
    mkdir -p -- "$VPS_SSH_HOME/.ssh" || return 1
    chmod 700 "$VPS_SSH_HOME/.ssh" || return 1
    chown "$VPS_SSH_UID:$VPS_SSH_GID" "$VPS_SSH_HOME/.ssh" || return 1
    touch -- "$VPS_SSH_AUTH" || return 1
    chmod 600 "$VPS_SSH_AUTH" || return 1
    chown "$VPS_SSH_UID:$VPS_SSH_GID" "$VPS_SSH_AUTH"
}

vps_ssh_valid_key() {
    local key="$1" temp result
    [[ "$key" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-[A-Za-z0-9-]+|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)[[:space:]]+[A-Za-z0-9+/=]+([[:space:]].*)?$ ]] || return 1
    temp=$(mktemp /tmp/vps-public-key.XXXXXX) || return 1
    printf '%s\n' "$key" > "$temp"
    ssh-keygen -lf "$temp" >/dev/null 2>&1
    result=$?
    rm -f -- "$temp"
    return "$result"
}

vps_ssh_add_key() {
    local key="$1"
    vps_ssh_valid_key "$key" || { echo "公钥格式无效" >&2; return 1; }
    vps_ssh_prepare_auth || return 1
    if grep -Fxq -- "$key" "$VPS_SSH_AUTH"; then
        echo "公钥已存在"
        return 0
    fi
    printf '%s\n' "$key" >> "$VPS_SSH_AUTH" || return 1
    echo "公钥已添加到 $VPS_SSH_AUTH"
}

vps_ssh_import_url() {
    local url="$1" temp line key
    local -a keys=()
    [[ "$url" == https://* ]] || { echo "只接受 HTTPS 公钥地址" >&2; return 1; }
    temp=$(mktemp /tmp/vps-public-keys.XXXXXX) || return 1
    if ! curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 30 -o "$temp" "$url" ||
       [ "$(wc -c < "$temp")" -gt 131072 ]; then
        rm -f -- "$temp"
        echo "公钥下载失败或文件过大" >&2
        return 1
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        line=${line%$'\r'}
        [ -z "$line" ] && continue
        [[ "$line" == \#* ]] && continue
        if ! vps_ssh_valid_key "$line" || [ "${#keys[@]}" -ge 32 ]; then
            rm -f -- "$temp"
            echo "下载内容包含无效公钥或超过 32 条" >&2
            return 1
        fi
        keys+=("$line")
    done < "$temp"
    rm -f -- "$temp"
    [ "${#keys[@]}" -gt 0 ] || { echo "未找到公钥" >&2; return 1; }
    for key in "${keys[@]}"; do vps_ssh_add_key "$key" || return 1; done
}

vps_ssh_generate_key() {
    local key_path="$VPS_SSH_HOME/.ssh/vps-toolbox-ed25519-$(date +%Y%m%d%H%M%S)"
    vps_ssh_prepare_auth || return 1
    [ ! -e "$key_path" ] || { echo "密钥文件已存在" >&2; return 1; }
    (umask 077; ssh-keygen -q -t ed25519 -N '' -C "$VPS_SSH_USER@vps-toolbox" -f "$key_path") || return 1
    chown "$VPS_SSH_UID:$VPS_SSH_GID" "$key_path" "$key_path.pub" || return 1
    vps_ssh_add_key "$(cat "$key_path.pub")" || return 1
    echo "私钥保存在 $key_path。请安全复制到登录客户端，测试成功后再关闭密码登录。"
}

vps_ssh_strip_policy() {
    local source="$1" begin end begin_line end_line
    begin=$(grep -cxF '# BEGIN VPS Toolbox SSH key mode' "$source" || true)
    end=$(grep -cxF '# END VPS Toolbox SSH key mode' "$source" || true)
    [ "$begin" -eq "$end" ] && [ "$begin" -le 1 ] || return 1
    if [ "$begin" -eq 1 ]; then
        begin_line=$(grep -nxF '# BEGIN VPS Toolbox SSH key mode' "$source" | cut -d: -f1)
        end_line=$(grep -nxF '# END VPS Toolbox SSH key mode' "$source" | cut -d: -f1)
        [ "$begin_line" -lt "$end_line" ] || return 1
    fi
    awk '$0 == "# BEGIN VPS Toolbox SSH key mode" {skip=1; next}
         $0 == "# END VPS Toolbox SSH key mode" {skip=0; next}
         !skip {print}' "$source"
}

vps_ssh_render_policy() {
    local mode="$1" source="$2"
    [[ "$mode" == on || "$mode" == stage || "$mode" == off ]] || return 1
    vps_ssh_strip_policy "$source" || return 1
    if [ "$mode" != off ]; then
        [[ "${VPS_SSH_USER:-}" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] || return 1
        printf '# BEGIN VPS Toolbox SSH key mode\nMatch User %s\n    PubkeyAuthentication yes\n' "$VPS_SSH_USER"
        if [ "$mode" = on ]; then
            printf '    PasswordAuthentication no\n    KbdInteractiveAuthentication no\n    AuthenticationMethods publickey\n'
        fi
        printf 'Match all\n# END VPS Toolbox SSH key mode\n'
    fi
}

vps_ssh_policy() {
    local mode="$1" config=/etc/ssh/sshd_config sshd_bin backup candidate effective auth_methods managed_user
    local client_addr=${SSH_CONNECTION%% *}
    client_addr=${client_addr:-127.0.0.1}
    [[ "$mode" == on || "$mode" == stage || "$mode" == off ]] || return 1
    [ "$(id -u)" -eq 0 ] || { echo "需要 root 权限" >&2; return 1; }
    sshd_bin=$(command -v sshd || true)
    [ -n "$sshd_bin" ] || sshd_bin=/usr/sbin/sshd
    [ -f "$config" ] && [ ! -L "$config" ] && [ -x "$sshd_bin" ] || {
        echo "未找到可管理的 OpenSSH 配置" >&2; return 1
    }
    managed_user=$(awk '$0=="# BEGIN VPS Toolbox SSH key mode" {inside=1; next}
        $0=="# END VPS Toolbox SSH key mode" {inside=0}
        inside && $1=="Match" && $2=="User" {print $3; exit}' "$config")
    if [ -n "$managed_user" ] && [ "$managed_user" != "$VPS_SSH_USER" ]; then
        echo "当前工具箱策略属于 $managed_user，请选择该用户移除策略后再切换用户" >&2
        return 1
    fi
    if [ "$mode" = stage ] && awk '
        $0 == "# BEGIN VPS Toolbox SSH key mode" {inside=1; next}
        $0 == "# END VPS Toolbox SSH key mode" {inside=0; next}
         inside && $1 == "PasswordAuthentication" && $2 == "no" {found=1}
        END {exit !found}' "$config"; then
        echo "当前已是仅密钥模式；如需移除策略，请使用菜单中的恢复选项" >&2
        return 1
    fi
    backup=$(mktemp /etc/ssh/sshd_config.vps-backup.XXXXXX) || return 1
    candidate=$(mktemp /etc/ssh/.sshd_config.vps.XXXXXX) || { rm -f -- "$backup"; return 1; }
    cp -p -- "$config" "$backup" || { rm -f -- "$backup" "$candidate"; return 1; }
    if ! vps_ssh_render_policy "$mode" "$config" > "$candidate"; then
        rm -f -- "$backup" "$candidate"
        echo "SSH 工具箱配置标记不完整，未做修改" >&2
        return 1
    fi
    if ! "$sshd_bin" -t -f "$candidate"; then
        rm -f -- "$candidate"
        echo "候选 SSH 配置无效，原配置未修改；备份: $backup" >&2
        return 1
    fi
    if [ "$mode" != off ]; then
        effective=$("$sshd_bin" -T -f "$candidate" -C "user=$VPS_SSH_USER,host=localhost,addr=$client_addr") || {
            rm -f -- "$candidate"; return 1;
        }
        auth_methods=$(printf '%s\n' "$effective" | awk '$1=="authenticationmethods" {print $2; exit}')
        if ! printf '%s\n' "$effective" | grep -qx 'pubkeyauthentication yes' ||
           { [ "$VPS_SSH_USER" = root ] && ! printf '%s\n' "$effective" | grep -Eq '^permitrootlogin (yes|prohibit-password|without-password)$'; } ||
           [[ ! "${auth_methods:-any}" =~ ^(any|publickey)$ ]] ||
           { [ "$mode" = on ] && { ! printf '%s\n' "$effective" | grep -qx 'passwordauthentication no' ||
                                   ! printf '%s\n' "$effective" | grep -qx 'kbdinteractiveauthentication no'; }; }; then
            rm -f -- "$candidate"
            echo "现有 Match/认证规则阻止目标策略生效，原配置未修改；备份: $backup" >&2
            return 1
        fi
    fi
    chown root:root "$candidate" && chmod 600 "$candidate" && mv -f -- "$candidate" "$config" || {
        rm -f -- "$candidate" "$backup"
        return 1
    }
    if "$sshd_bin" -t && vps_ssh_reload; then
        if [ "$mode" != off ]; then
            effective=$("$sshd_bin" -T -C "user=$VPS_SSH_USER,host=localhost,addr=${client_addr:-127.0.0.1}" 2>/dev/null)
            auth_methods=$(printf '%s\n' "$effective" | awk '$1 == "authenticationmethods" {print $2; exit}')
            if printf '%s\n' "$effective" | grep -qx 'pubkeyauthentication yes' &&
               { [ "$VPS_SSH_USER" != root ] || printf '%s\n' "$effective" | grep -Eq '^permitrootlogin (yes|prohibit-password|without-password)$'; } &&
               { { [ "$mode" = stage ] && [[ "${auth_methods:-any}" =~ ^(any|publickey(,publickey)*)$ ]]; } || {
                   printf '%s\n' "$effective" | grep -qx 'passwordauthentication no' &&
                   printf '%s\n' "$effective" | grep -qx 'kbdinteractiveauthentication no' &&
                   [[ "${auth_methods:-any}" =~ ^(any|publickey(,publickey)*)$ ]];
               }; }; then
                if [ "$mode" = stage ]; then
                    echo "公钥认证已开启，原有密码登录策略保持不变；备份: $backup"
                    echo "请在新终端测试密钥登录，成功后再选择仅密钥模式。"
                else
                    echo "$VPS_SSH_USER 的仅密钥登录模式已开启；原配置备份: $backup"
                    echo "请保持当前连接，使用新终端再次验证密钥登录。"
                fi
                return 0
            fi
        else
            echo "工具箱的密钥登录策略已移除；修改前备份: $backup"
            return 0
        fi
    fi
    if cp -p -- "$backup" "$config" && vps_ssh_reload; then
        echo "SSH 策略未生效，已恢复原配置；备份: $backup" >&2
    else
        echo "SSH 自动恢复未完成，请通过控制台检查；备份: $backup" >&2
    fi
    return 1
}

vps_ssh_key_menu() {
    root_use || return
    local choice input username status client_addr=${SSH_CONNECTION%% *}
    read -r -e -p "管理哪个 Linux 用户的密钥？(默认 root): " input || return 0
    vps_ssh_select_user "${input:-root}" || return 1
    while true; do
        clear
        status=$("$(command -v sshd || echo /usr/sbin/sshd)" -T -C "user=$VPS_SSH_USER,host=localhost,addr=${client_addr:-127.0.0.1}" 2>/dev/null | awk '$1=="pubkeyauthentication" || $1=="passwordauthentication" {printf "%s=%s ", $1, $2}')
        echo "用户密钥登录模式：$VPS_SSH_USER"
        echo "当前策略: ${status:-无法读取}"
        echo "1. 手动添加公钥     2. 从 GitHub 导入公钥"
        echo "3. 从 HTTPS 地址导入公钥"
        echo "4. 在服务器生成 ED25519 密钥对"
        echo "5. 查看已添加公钥的指纹"
        echo "6. 开启公钥认证（保留现有密码登录策略）"
        echo "7. 开启该用户的仅密钥登录（关闭该用户的 SSH 密码登录）"
        echo "8. 移除工具箱的密钥登录策略"
        echo "0. 返回"
        read -r -e -p "请输入你的选择: " choice || return 0
        case "$choice" in
            1) read -r -e -p "粘贴 SSH 公钥: " input || return 0; vps_ssh_add_key "$input"; break_end ;;
            2)
                read -r -e -p "GitHub 用户名: " username || return 0
                if [[ "$username" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$ ]]; then
                    vps_ssh_import_url "https://github.com/${username}.keys"
                else echo "GitHub 用户名无效" >&2; fi
                break_end ;;
            3) read -r -e -p "HTTPS 公钥地址: " input || return 0; vps_ssh_import_url "$input"; break_end ;;
            4) vps_ssh_generate_key; break_end ;;
            5)
                if [ -f "$VPS_SSH_AUTH" ]; then ssh-keygen -lf "$VPS_SSH_AUTH"; else echo "暂无公钥"; fi
                break_end ;;
            6)
                if [ ! -s "$VPS_SSH_AUTH" ] || ! ssh-keygen -lf "$VPS_SSH_AUTH" >/dev/null 2>&1; then
                    echo "请先添加有效公钥" >&2
                else
                    vps_ssh_policy stage
                fi
                break_end ;;
            7)
                if [ ! -s "$VPS_SSH_AUTH" ] || ! ssh-keygen -lf "$VPS_SSH_AUTH" >/dev/null 2>&1; then
                    echo "请先添加公钥并在新连接中测试" >&2
                else
                    echo "这会关闭 $VPS_SSH_USER 的 SSH 密码登录。请保持当前连接，在另一个终端测试该用户的密钥登录。"
                    read -r -e -p "已成功测试密钥登录后，输入 已测试 继续: " input || return 0
                    [ "$input" = 已测试 ] && vps_ssh_policy on || echo "操作已取消或未成功"
                fi
                break_end ;;
            8) vps_ssh_policy off; break_end ;;
            0) break ;;
            *) echo "无效选择"; sleep 1 ;;
        esac
    done
}

# ============ DNS 地址 ============

