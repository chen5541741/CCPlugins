# Marketplaces 分发
[通过gitlab分发Marketplaces](https://code.claude.com/docs/en/plugin-marketplaces#host-on-other-git-services)

# 其他说明事项

## SSH 配置

下面给出在 Debian 系统上为 GitLab 仓库配置 SSH Key 的最简流程，全部命令可直接复制执行。

1. 安装必要软件  
   ```bash
   sudo apt update
   sudo apt install -y git openssh-client
   ```

2. 生成密钥（如已有可跳过）  
   ```bash
   ssh-keygen -t ed25519 -C "your_email@example.com"
   # 一路回车，不设置密码更方便 CI/自动化
   ```
   默认生成 `~/.ssh/id_ed25519`（私钥）和 `~/.ssh/id_ed25519.pub`（公钥）。

3. 把公钥加入 GitLab  
   ```bash
   cat ~/.ssh/id_ed25519.pub
   ```
   复制输出的整行内容 → 登录 GitLab → 右上角头像 → **Preferences** → **SSH Keys** → 粘贴到 **Key** 区域，起个 Title → **Add key** 。

4. 让 ssh-agent 一直加载私钥（可选，但推荐）  
   ```bash
   eval "$(ssh-agent -s)"
   ssh-add ~/.ssh/id_ed25519
   ```
   可把前两句写进 `~/.bashrc` 或 `~/.zshrc`，以后开机自动运行 。

5. 首次连接验证  
   ```bash
   ssh -T git@gitlab.com          # 官方 SaaS 用这行
   # 自建实例把 gitlab.com 换成你自己的域名
   ```
   看到 **Welcome to GitLab, @username!** 即成功 。

6. 克隆/推送代码  
   ```bash
   git clone git@gitlab.com:group/project.git
   ```
   以后任何 `git pull/push` 都不再询问账号密码。

常见坑  
- **Permission denied (publickey)**：90% 是公钥没贴对或贴漏了末尾的换行。  
- **Agent admitted failure to sign**：先执行 `ssh-add -l` 看密钥是否已加载；没有就重新 `ssh-add`。  
- 公司网络拦截 22 端口：把 `~/.ssh/config` 里端口改成 443，或让管理员开 22。

完成以上 6 步，Debian 就能用 SSH 协议无缝读写 GitLab 仓库了。