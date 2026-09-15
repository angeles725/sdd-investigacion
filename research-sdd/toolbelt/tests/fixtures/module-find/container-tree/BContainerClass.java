package com.example;
public class BContainerClass extends BComponent {
    @NiagaraProperties({
        @NiagaraProperty(name = "alpha", type = "baja:StatusBoolean", flags = Flags.SUMMARY),
        @NiagaraProperty(name = "beta", type = "baja:StatusNumeric", flags = Flags.OPERATOR)
    })
    @NiagaraActions({
        @NiagaraAction(name = "startOp", flags = Flags.HIDDEN),
        @NiagaraAction(name = "stopOp", flags = Flags.OPERATOR)
    })
    public void doStartOp() {}
    public void doStopOp() {}
}
