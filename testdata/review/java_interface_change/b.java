package com.example;

public interface Greeter {
    String name();
    default String greet() { return "hi " + name(); }
}
