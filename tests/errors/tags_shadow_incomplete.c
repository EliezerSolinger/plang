struct u { int a; };
int main(void) {
    union u;            /* declares a NEW incomplete union u in this scope */
    union u my_union;   /* invalid: value of an incomplete type */
    return 0;
}
