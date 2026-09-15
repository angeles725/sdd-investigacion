package com.example;
public class BCommentParen extends BBase {
    @NiagaraProperty(name = "first", type = "boolean")  // trailing comment with ( unbalanced
    @NiagaraProperty(name = "second", type = "numeric")
    public void doSomething() {}
}
