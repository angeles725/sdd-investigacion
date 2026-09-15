package com.example;
public class BSlotClass extends BComponent {
    @NiagaraProperty(name = "enabled", type = "boolean", flags = Flags.SUMMARY)
    @NiagaraProperty(
        name = "setpoint",
        type = "baja:StatusNumeric",
        flags = Flags.SUMMARY | Flags.OPERATOR
    )
    @NiagaraAction(name = "reset", flags = Flags.OPERATOR)
    public void doReset() {}
}
