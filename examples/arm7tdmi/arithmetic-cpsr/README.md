# ARM7 算术与 CPSR

这是原创的最小 ARM state 示例。`mov` 先把 `r0` 设为 256，带 `S` 后缀的 `adds` 再加 67，因此执行到 `mrs` 后 `r0 = 323`；`r1` 保存此时的 CPSR，便于在调试器中观察 N/Z/C/V。

```sh
yagarto-mac build
yagarto-mac disassemble
yagarto-mac debug
```

若本机有支持 `target sim` 的 GDB，可在入口后单步两条指令并检查 `r0`。没有该 simulator 时，构建和反汇编仍可审计 `256 + 67 = 323`，但不能把静态检查写成“已运行”。
