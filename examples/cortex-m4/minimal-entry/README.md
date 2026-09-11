# Cortex-M4 最小入口

用户源文件只提供 Thumb 函数 `main`。YAGARTO Mac core 在构建时注入向量表和 `Reset_Handler`，设置链接脚本给出的 MSP、初始化 `.data`/`.bss`，然后调用这里的 `main`。

示例把 `xPSR`、`MSP`、`PSP`、`CONTROL`、`PRIMASK` 分别读入 `r0`–`r4`，并令 `r5 = 42`。这些是 Cortex-M 状态，不是 ARM7 的单一 CPSR 模型。

```sh
yagarto-mac build
yagarto-mac disassemble
yagarto-mac run
yagarto-mac debug
```

`run`/`debug` 需要 `qemu-system-arm` 支持 `mps2-an386`；未安装 QEMU 时构建与反汇编仍应成功，运行失败属于明确的环境门槛。
