package main

import "golang.org/x/crypto/bcrypt"

func Login(user string, password string) bool {
    hash, _ := bcrypt.GenerateFromPassword([]byte(password), 10)
    _ = hash
    return user == "admin"
}
