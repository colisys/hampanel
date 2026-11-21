import { defineConfig } from 'vitepress'

export default defineConfig({
  lang: 'zh-CN',
  title: 'Hampanel',
  description: '原生客户端驱动的开源服务器运维面板',
  cleanUrls: true,
  head: [
    ['link', { rel: 'icon', type: 'image/svg+xml', href: '/hampanel-ham.svg' }],
    ['link', { rel: 'apple-touch-icon', href: '/hampanel-ham.png' }],
    ['meta', { name: 'theme-color', content: '#F3EEE2' }],
    ['meta', { property: 'og:type', content: 'website' }],
    ['meta', { property: 'og:title', content: 'Hampanel 文档' }],
    ['meta', { property: 'og:description', content: '原生客户端驱动的开源服务器运维面板' }],
  ],
  markdown: {
    theme: { light: 'github-light', dark: 'github-dark' },
    lineNumbers: false,
  },
  sitemap: {
    hostname: 'https://hampanel.dawncall.work',
  },
  themeConfig: {
    logo: '/hampanel-ham.png',
    siteTitle: 'Hampanel',
    outline: { level: [2, 3], label: '本页目录' },
    docFooter: { prev: '上一篇', next: '下一篇' },
    returnToTopLabel: '回到顶部',
    sidebarMenuLabel: '目录',
    darkModeSwitchLabel: '外观',
    lastUpdated: { text: '最近更新' },
    nav: [
      { text: '开始', link: '/guide/' },
      { text: '功能', link: '/features/' },
      { text: '应用商店', link: '/store/' },
      { text: '参考', link: '/reference/platforms' },
      { text: '使用条款', link: '/terms' },
    ],
    sidebar: {
      '/guide/': [
        {
          text: '开始使用',
          items: [
            { text: '产品概述', link: '/guide/' },
            { text: '安装受控端', link: '/guide/install' },
            { text: '安装客户端', link: '/guide/client' },
            { text: '首次连接', link: '/guide/first-connect' },
            { text: '升级与更新', link: '/guide/update' },
          ],
        },
      ],
      '/features/': [
        {
          text: '功能',
          items: [
            { text: '功能总览', link: '/features/' },
            { text: '概览与主机运维', link: '/features/host' },
            { text: '文件与恢复', link: '/features/files' },
            { text: '网站与证书', link: '/features/sites' },
            { text: '容器与运行环境', link: '/features/containers' },
            { text: '网络接入与防护', link: '/features/network' },
            { text: '安全中心', link: '/features/security' },
            { text: 'AI 助手与通知', link: '/features/ai' },
          ],
        },
      ],
      '/store/': [
        {
          text: '应用商店',
          items: [
            { text: '商店概览', link: '/store/' },
            { text: '应用目录', link: '/store/catalog' },
            { text: '脚本与 Nix', link: '/store/tools' },
          ],
        },
      ],
      '/reference/': [
        {
          text: '参考',
          items: [
            { text: '平台差异', link: '/reference/platforms' },
            { text: '安全模型', link: '/reference/security' },
            { text: '数据与目录', link: '/reference/data' },
            { text: '常见问题', link: '/reference/faq' },
          ],
        },
        {
          text: '法律',
          items: [{ text: '使用条款与合规', link: '/terms' }],
        },
      ],
    },
    socialLinks: [
      { icon: 'github', link: 'https://github.com/colisys/hampanel' },
    ],
    footer: {
      message:
        'GPL-3.0-or-later · 使用时须遵守适用法律法规与<a href="/terms">使用条款</a>',
      copyright: 'Hampanel',
    },
    search: {
      provider: 'local',
      options: {
        translations: {
          button: { buttonText: '搜索文档', buttonAriaLabel: '搜索文档' },
          modal: {
            noResultsText: '没有找到结果',
            resetButtonTitle: '清除查询',
            footer: { selectText: '选择', navigateText: '切换', closeText: '关闭' },
          },
        },
      },
    },
  },
})
