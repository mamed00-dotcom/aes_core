// ===========================================================================
// main.c - NEORV32 firmware: drive the AES-128 coprocessor over MMIO
// Project: AES-128 Core - real RISC-V integration (NEORV32)
// Author:  Mohammed Hajjar
//
// Bare-metal (no NEORV32 BSP): the AES coprocessor is plain memory-mapped IO
// at 0x9000_0000 (decoded onto NEORV32's external bus / XBUS), reached through
// the Wishbone->AXI4-Lite bridge. The program:
//
//   1. loads the AES key (4 x 32-bit writes), pulses KEY_LOAD, waits key_ready
//   2. writes one plaintext block (4 x DIN), pulses PUSH
//   3. polls STATUS until the output FIFO is non-empty
//   4. reads the ciphertext back (4 x DOUT), pulses POP
//   5. compares against the FIPS-197 Appendix C.1 known-answer ciphertext
//   6. drives a PASS/FAIL sentinel onto GPIO for the testbench to observe
//
// FIPS-197 C.1 vector:
//   key = 000102030405060708090a0b0c0d0e0f
//   pt  = 00112233445566778899aabbccddeeff
//   ct  = 69c4e0d86a7b0430d8cdb78070b4c55a
// ===========================================================================

#include <stdint.h>

#define AES_BASE   0x90000000u
#define AES(off)   (*(volatile uint32_t *)(AES_BASE + (off)))

#define REG_CTRL   0x00u    // W: bit0 PUSH, bit1 POP, bit2 KEY_LOAD, bit3 FLUSH
#define REG_STATUS 0x04u    // R: see bit masks below
#define REG_KEY0   0x10u    // KEY0 = key[127:96]
#define REG_DIN0   0x20u    // DIN0 = plaintext[127:96]
#define REG_DOUT0  0x30u    // DOUT0 = ciphertext[127:96] (FIFO head)

#define CTRL_PUSH      0x1u
#define CTRL_POP       0x2u
#define CTRL_KEY_LOAD  0x4u

#define ST_OUT_EMPTY  (1u << 3)
#define ST_KEY_READY  (1u << 4)

// NEORV32 GPIO output port (PORT_OUT) - watched by the testbench
#define GPIO_OUT   (*(volatile uint32_t *)0xFFFC0004u)

#define SENTINEL_RUN   0x00000000u
#define SENTINEL_PASS  0x600DC0DEu
#define SENTINEL_FAIL  0xBAD00000u

int main(void)
{
    static const uint32_t key[4] = {
        0x00010203u, 0x04050607u, 0x08090a0bu, 0x0c0d0e0fu
    };
    static const uint32_t pt[4] = {
        0x00112233u, 0x44556677u, 0x8899aabbu, 0xccddeeffu
    };
    static const uint32_t ct_exp[4] = {
        0x69c4e0d8u, 0x6a7b0430u, 0xd8cdb780u, 0x70b4c55au
    };
    uint32_t ct[4];
    int i, ok;

    GPIO_OUT = SENTINEL_RUN;

    // 1. program the key and start the one-time key expansion
    for (i = 0; i < 4; i++)
        AES(REG_KEY0 + (uint32_t)(i << 2)) = key[i];
    AES(REG_CTRL) = CTRL_KEY_LOAD;
    while ((AES(REG_STATUS) & ST_KEY_READY) == 0u)
        ;

    // 2. stage one plaintext block and push it into the pipeline
    for (i = 0; i < 4; i++)
        AES(REG_DIN0 + (uint32_t)(i << 2)) = pt[i];
    AES(REG_CTRL) = CTRL_PUSH;

    // 3. wait for a ciphertext result to appear
    while ((AES(REG_STATUS) & ST_OUT_EMPTY) != 0u)
        ;

    // 4. read the result and free the FIFO slot
    for (i = 0; i < 4; i++)
        ct[i] = AES(REG_DOUT0 + (uint32_t)(i << 2));
    AES(REG_CTRL) = CTRL_POP;

    // 5. check against the known answer
    ok = 1;
    for (i = 0; i < 4; i++)
        if (ct[i] != ct_exp[i])
            ok = 0;

    // 6. report to the testbench and halt
    GPIO_OUT = ok ? SENTINEL_PASS : SENTINEL_FAIL;

    for (;;)
        ;
    return 0;
}
