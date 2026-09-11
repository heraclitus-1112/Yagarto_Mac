# ARM7 数组寻址

`numbers` 是 32 位整数数组。`r1 = 3` 是从 0 开始的下标，`lsl #2` 把下标乘以每项 4 字节，因此 `ldr r2, [r0, r1, lsl #2]` 读取第 4 项，停止时 `r2 = 40`。

```sh
yagarto-mac build
yagarto-mac disassemble
yagarto-mac debug
```

这个例子刻意把“下标”和“字节偏移”分开，便于在 GDB memory 窗口中逐字查看数组。
