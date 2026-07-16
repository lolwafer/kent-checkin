# Kent Senior Center 打卡系统

前台打卡程序,记录每天上下班时间,自动生成月度报表。

## 一次性部署步骤

### 1. Supabase 初始化

在 https://supabase.com 登录 `lolwafer@me.com` 账号,创建新项目 "kent":
- 点 "New Project"
- Name: `kent`
- Database Password: 设定一个强密码
- Region: 选最近的地区
- 点 "Create new project"

等待项目初始化完成(约 2 分钟),然后:
- 进 SQL Editor
- 新建 SQL 文件,复制粘贴 `supabase/migrations/001_init.sql` 全部内容
- 点执行

初始化完后,从项目的 "Settings" → "API" 里复制:
- **Project URL** (如 https://xxxxx.supabase.co)
- **Anon Key** (public)

### 2. 获取 API 凭证,配置到 Cloudflare

从 Supabase 复制的 URL 和 Key,后续要在 Cloudflare Pages 项目配置成环境变量。

### 3. Cloudflare Pages 连接

1. 在 Cloudflare 登录,进 Pages
2. 连接 GitHub 账户,授权 `lolwafer` 
3. 选 `lolwafer/kent-checkin` 仓库
4. Build settings:
   - **Framework preset**: None
   - **Build command**: (留空)
   - **Build output directory**: `public`
5. 点 "Save and Deploy"

### 4. 配置环境变量和自定义域

部署后,进项目设置:
- **Environment Variables** (Production):
  - `SUPABASE_URL`: 粘贴 Supabase Project URL
  - `SUPABASE_KEY`: 粘贴 Supabase Anon Key
- **Custom Domains**: 加 `kent.pages.dev` (需要 Cloudflare DNS 权限)

### 5. 构建环境变量到 HTML

目前代码里用的是占位符,需要在构建时替换。有两个方案:

**方案 A(简单)**: 手动编辑 `public/index.html`,找到:
```
const SUPABASE_URL = 'SUPABASE_URL_PLACEHOLDER';
const SUPABASE_KEY = 'SUPABASE_KEY_PLACEHOLDER';
```
直接替换成你的实际值,push 即可。

**方案 B(推荐)**: 用 Cloudflare Worker 动态注入(待实现)。

选方案 A 最快,只是 Key 在代码里(但已设置只能读权限给 owner,插入权限给所有人,所以员工看不到数据)。

## 日常使用

### 打卡
1. 打开 https://kent.pages.dev
2. 选择员工名字
3. 点"上班打卡"或"下班打卡" → 浏览器定位 → 检查是否在中心 150 米内
4. 打卡成功

### 查看报表
切到"报表"页,选月份,看每天的打卡时间和合计小时数。

## 代码改动 & 自动部署

说改什么,我会:
1. 改代码 → git push
2. Cloudflare Pages 自动部署(约 1 分钟)

无需自己操作 GitHub/Cloudflare/Supabase。
