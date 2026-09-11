# ARM7 栈与子程序

入口先把 `sp` 指向示例自带的 256 字节栈顶，再用 `bl` 调用子程序。子程序通过 full-descending 形式的 `stmdb sp!` 保存 `r4/lr`，返回时用 `ldmia sp!, {r4, pc}` 恢复并返回；最终 `r0 = 20 + 22 = 42`。

```sh
yagarto-mac build
yagarto-mac disassemble
yagarto-mac debug
```

这只是教学用的裸机栈区域，不包含操作系统、异常栈或越界保护。
