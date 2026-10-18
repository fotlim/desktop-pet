# 模型包格式

`models/` 下**一个目录 = 一个模型包**,目录名就是包 id(命令行 `-Model <id>` 用的就是它)。
程序启动时会扫一遍 `models/*/pet.json`,菜单里按「包 · 配色」列出来。

```
models/
  dsh-pet/                 ← 包 id = dsh-pet
    pet.json               ← 必需的清单
    idle/000.png ...       ← 待机帧(必需)
    sleep/ ... walk/ ...   ← 其它状态帧(可选,缺了会退回 idle)
    wave/ look/ cat/ ...   ← 动作帧(可选,几个就能出现在「动作」菜单里)
    memes/00.png ...       ← 表情包(可选)
    sayings.txt            ← 碎碎念句子,一行一句(可选)
    NOTICE.txt             ← 素材出处/许可(强烈建议)
```

## pet.json

```jsonc
{
  "name": "蓝色女仆(dsh-pet)",     // 菜单里显示的名字,缺省用目录名
  "author": "PC2005-cloud",        // 可选
  "source": "https://github.com/PC2005-cloud/dsh-pet",   // 「关于」菜单打开的链接
  "license": "MIT",
  "fps": 24,                       // 帧素材的原生帧率

  // 动作 / 状态列表。id 对应目录名,label 是菜单文字
  "anims": [
    { "id": "idle",  "label": "待机呼吸", "w": 236, "h": 291, "frames": 60 },
    { "id": "sleep", "label": "打盹",     "w": 240, "h": 286, "frames": 34 },
    { "id": "walk",  "label": "漂浮踏步", "w": 241, "h": 294, "frames": 34 },
    { "id": "wave",  "label": "挥手回应", "w": 233, "h": 312, "frames": 34,
      "ms": 10000 },                                        // 这段动作播多久(毫秒)
    { "id": "cat",   "label": "撸猫",     "w": 240, "h": 288, "frames": 34,
      "ms": 10000, "pingpong": true }                        // 往返循环(默认 true)
  ],

  // 表情包,id 对应 memes/<id>.png
  "memes": [ { "id": "00", "label": "Ciallo", "w": 300, "h": 300 } ],

  // 配色变体:同一个包的多套外观,不额外占磁盘
  "variants": [
    { "id": "default", "name": "原色" },
    { "id": "night",   "name": "夜色", "filters": { "bright": 0.75, "saturate": 0.85 } },
    { "id": "vivid",   "name": "浓彩", "filters": { "saturate": 1.5 } },
    { "id": "mono",    "name": "墨白", "filters": { "saturate": 0, "bright": 1.05 } }
  ]
}
```

### 字段说明

| 字段 | 说明 |
| --- | --- |
| `anims[].w` / `h` | 帧的实际像素尺寸(仅用于日志和漫画式的框选,写错不影响播放) |
| `anims[].frames` | 帧数(同上,程序其实按目录里的 PNG 数量走) |
| `anims[].ms` | **这段动作播多久**。不写就按「帧数 ÷ 帧率」播一遍(1.4 秒左右);原项目每段是 10 秒,所以默认写 `10000` |
| `anims[].pingpong` | 动作循环时是否**往返播**。默认 `true`(0→末→0,接缝不硬跳);带位移的动作建议 `false` |
| `anims[].fps` | 单段动作自己的帧率(可选,缺省用顶层 `fps`) |
| `variants[].filters` | 配色:颜色矩阵,`hue`(色相偏移角度)/ `saturate`(饱和度倍数)/ `bright`(亮度倍数),都不写就是原色 |

- 帧按文件名排序播放,建议 `000.png`、`001.png`… 零填充
- 帧必须是 **带透明通道的 PNG**(RGBA),背景透明
- `idle` 目录必须有;`sleep` / `walk` 没有的话会一直用 `idle`
- 动作 id 不要用 `idle` / `sleep` / `walk`(这三个是状态,不放进「动作」菜单)

## 加一只新角色

1. 在 `models/` 下新建目录,比如 `models/my-pet/`
2. 按上面的结构放 `idle/` 等帧目录,写一份 `pet.json`
3. 右键宠物 → 模型 →「重新扫描模型」;或者 `.\DesktopPet.ps1 -Mode list` 看一下有没有认出来
4. 点一下就能切过去(位置、大小、设置都保留)

## 配色是怎么实现的

帧载入时,把颜色矩阵用 GDI+ 的 `ImageAttributes`/`ColorMatrix` 一次性画进内存位图,之后播放的每一帧都是
已经上好色的 HBITMAP —— 所以**切换配色不影响帧率**。缓存 key 里带了包 id 和配色 id,换配色不会串图。

> 注意:GDI+ 的 `ColorMatrix` 是按「行 = 输入通道、列 = 输出通道」用的(等价于 `out = in × M`),
> 所以饱和度矩阵要把亮度权重放在每一行里 —— 写反了会得到「灰阶变绿」这种结果。
