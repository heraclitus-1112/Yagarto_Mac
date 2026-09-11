# ARM7 条件分支

示例用 `cmp r0, #5` 更新 CPSR，再由有符号条件 `bgt` 选择路径。当前输入为 7，所以到达停止循环时 `r1 = 1`；`r2` 保留比较后的 CPSR，可同时核对条件码。

```sh
yagarto-mac build
yagarto-mac disassemble
yagarto-mac debug
```

这里比较的是有符号整数。若练习无符号大小关系，应改用 `bhi`/`bls` 等无符号条件。
