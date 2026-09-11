# STM32F4-Discovery PD12 LED

这是一个直接访问寄存器的最小真板示例：打开 GPIOD 时钟，把 PD12 配置为通用输出，再通过 BSRR 置位。PD12 连接到 STM32F4-Discovery 板上的绿色 LED。

```sh
yagarto-mac build
yagarto-mac disassemble

# 下面命令会真实写入已连接的开发板，必须由使用者明确确认：
yagarto-mac flash --yes
yagarto-mac debug
```

只有连接正确的 STM32F4-Discovery 真板与 ST-Link 时才能观察到 LED。Cortex-M4 的通用 QEMU profile 不是 STM32F407 外设模型，仿真不能真实显示这颗 LED；本仓库也不会自动执行烧录。
