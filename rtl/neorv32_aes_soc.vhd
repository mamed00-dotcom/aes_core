-- =========================================================================
-- Module:  neorv32_aes_soc.vhd
-- Project: AES-128 Core - real RISC-V integration (NEORV32)
-- Author:  Mohammed Hajjar
-- Date:    June 2026
--
-- Description:
--   Minimal SoC that wires a real RISC-V core (NEORV32, VHDL) to the
--   AES-128 pipelined coprocessor (aes_coproc.v, Verilog) so that compiled
--   firmware running on the CPU drives the AES hardware over a real bus:
--
--     neorv32_top --XBUS(Wishbone)--> wb_to_axil --AXI4-Lite--> aes_coproc
--
--   The CPU sees the coprocessor as plain MMIO at 0x9000_0000 (decoded onto
--   the external bus, which is everything outside internal IMEM/DMEM/IO).
--   Firmware loads the key, pushes a plaintext block, polls STATUS, reads the
--   ciphertext back, checks it against the FIPS-197 C.1 known answer, and
--   reports PASS/FAIL on the GPIO output port (watched by the testbench).
--
--   This is a mixed-language design: NEORV32 is VHDL, the AES coprocessor and
--   the Wishbone->AXI4-Lite bridge are Verilog (instantiated here as
--   components and bound by name during elaboration).
--
--   Boot: BOOT_MODE_SELECT=2 => the CPU boots directly from the pre-initialized
--   IMEM image (neorv32_imem_image.vhd, regenerated from the firmware), so no
--   bootloader/UART handshake is needed in simulation.
-- =========================================================================

library ieee;
use ieee.std_logic_1164.all;

library neorv32;
use neorv32.neorv32_package.all;

entity neorv32_aes_soc is
  generic (
    CLOCK_HZ : natural := 100000000   -- 100 MHz simulation clock
  );
  port (
    clk_i     : in  std_ulogic;
    rstn_i    : in  std_ulogic;
    gpio_o    : out std_ulogic_vector(31 downto 0);  -- firmware PASS/FAIL sentinel
    aes_irq_o : out std_ulogic                       -- coprocessor IRQ (observation)
  );
end entity neorv32_aes_soc;

architecture rtl of neorv32_aes_soc is

  -- ---- XBUS (Wishbone-b4 classic) : CPU <-> bridge ----------------------
  signal xbus_adr   : std_ulogic_vector(31 downto 0);
  signal xbus_dat_w : std_ulogic_vector(31 downto 0);
  signal xbus_dat_r : std_ulogic_vector(31 downto 0);
  signal xbus_we    : std_ulogic;
  signal xbus_sel   : std_ulogic_vector(3 downto 0);
  signal xbus_stb   : std_ulogic;
  signal xbus_cyc   : std_ulogic;
  signal xbus_ack   : std_ulogic;
  signal xbus_err   : std_ulogic;

  -- ---- AXI4-Lite : bridge <-> aes_coproc (7-bit register window) --------
  signal axi_awaddr  : std_ulogic_vector(6 downto 0);
  signal axi_awprot  : std_ulogic_vector(2 downto 0);
  signal axi_awvalid : std_ulogic;
  signal axi_awready : std_ulogic;
  signal axi_wdata   : std_ulogic_vector(31 downto 0);
  signal axi_wstrb   : std_ulogic_vector(3 downto 0);
  signal axi_wvalid  : std_ulogic;
  signal axi_wready  : std_ulogic;
  signal axi_bresp   : std_ulogic_vector(1 downto 0);
  signal axi_bvalid  : std_ulogic;
  signal axi_bready  : std_ulogic;
  signal axi_araddr  : std_ulogic_vector(6 downto 0);
  signal axi_arprot  : std_ulogic_vector(2 downto 0);
  signal axi_arvalid : std_ulogic;
  signal axi_arready : std_ulogic;
  signal axi_rdata   : std_ulogic_vector(31 downto 0);
  signal axi_rresp   : std_ulogic_vector(1 downto 0);
  signal axi_rvalid  : std_ulogic;
  signal axi_rready  : std_ulogic;

  -- coprocessor interrupt: driven to the CPU machine-external IRQ and observed
  signal aes_irq_s   : std_ulogic;

  -- ---- Verilog components (bound by name at elaboration) ----------------
  component wb_to_axil
    port (
      clk           : in  std_ulogic;
      rst_n         : in  std_ulogic;
      wb_cyc_i      : in  std_ulogic;
      wb_stb_i      : in  std_ulogic;
      wb_we_i       : in  std_ulogic;
      wb_adr_i      : in  std_ulogic_vector(31 downto 0);
      wb_dat_i      : in  std_ulogic_vector(31 downto 0);
      wb_sel_i      : in  std_ulogic_vector(3 downto 0);
      wb_dat_o      : out std_ulogic_vector(31 downto 0);
      wb_ack_o      : out std_ulogic;
      wb_err_o      : out std_ulogic;
      m_axi_awaddr  : out std_ulogic_vector(6 downto 0);
      m_axi_awprot  : out std_ulogic_vector(2 downto 0);
      m_axi_awvalid : out std_ulogic;
      m_axi_awready : in  std_ulogic;
      m_axi_wdata   : out std_ulogic_vector(31 downto 0);
      m_axi_wstrb   : out std_ulogic_vector(3 downto 0);
      m_axi_wvalid  : out std_ulogic;
      m_axi_wready  : in  std_ulogic;
      m_axi_bresp   : in  std_ulogic_vector(1 downto 0);
      m_axi_bvalid  : in  std_ulogic;
      m_axi_bready  : out std_ulogic;
      m_axi_araddr  : out std_ulogic_vector(6 downto 0);
      m_axi_arprot  : out std_ulogic_vector(2 downto 0);
      m_axi_arvalid : out std_ulogic;
      m_axi_arready : in  std_ulogic;
      m_axi_rdata   : in  std_ulogic_vector(31 downto 0);
      m_axi_rresp   : in  std_ulogic_vector(1 downto 0);
      m_axi_rvalid  : in  std_ulogic;
      m_axi_rready  : out std_ulogic
    );
  end component;

  component aes_coproc
    port (
      clk           : in  std_ulogic;
      rst_n         : in  std_ulogic;
      s_axi_awaddr  : in  std_ulogic_vector(6 downto 0);
      s_axi_awprot  : in  std_ulogic_vector(2 downto 0);
      s_axi_awvalid : in  std_ulogic;
      s_axi_awready : out std_ulogic;
      s_axi_wdata   : in  std_ulogic_vector(31 downto 0);
      s_axi_wstrb   : in  std_ulogic_vector(3 downto 0);
      s_axi_wvalid  : in  std_ulogic;
      s_axi_wready  : out std_ulogic;
      s_axi_bresp   : out std_ulogic_vector(1 downto 0);
      s_axi_bvalid  : out std_ulogic;
      s_axi_bready  : in  std_ulogic;
      s_axi_araddr  : in  std_ulogic_vector(6 downto 0);
      s_axi_arprot  : in  std_ulogic_vector(2 downto 0);
      s_axi_arvalid : in  std_ulogic;
      s_axi_arready : out std_ulogic;
      s_axi_rdata   : out std_ulogic_vector(31 downto 0);
      s_axi_rresp   : out std_ulogic_vector(1 downto 0);
      s_axi_rvalid  : out std_ulogic;
      s_axi_rready  : in  std_ulogic;
      irq           : out std_ulogic
    );
  end component;

begin

  -- ====================================================================
  -- RISC-V processor (NEORV32) - base rv32i, internal IMEM/DMEM, XBUS, GPIO
  -- ====================================================================
  cpu_inst : neorv32_top
    generic map (
      CLOCK_FREQUENCY  => CLOCK_HZ,
      BOOT_MODE_SELECT => 2,            -- boot the pre-initialized IMEM image
      -- internal memories
      IMEM_EN          => true,
      IMEM_SIZE        => 16*1024,
      DMEM_EN          => true,
      DMEM_SIZE        => 8*1024,
      -- external bus for the AES coprocessor
      XBUS_EN          => true,
      XBUS_TIMEOUT     => 2048,
      -- GPIO for the firmware PASS/FAIL sentinel
      IO_GPIO_NUM      => 32
    )
    port map (
      clk_i      => clk_i,
      rstn_i     => rstn_i,
      -- XBUS (Wishbone) master out to the bridge
      xbus_adr_o => xbus_adr,
      xbus_dat_o => xbus_dat_w,
      xbus_cti_o => open,
      xbus_tag_o => open,
      xbus_we_o  => xbus_we,
      xbus_sel_o => xbus_sel,
      xbus_stb_o => xbus_stb,
      xbus_cyc_o => xbus_cyc,
      xbus_dat_i => xbus_dat_r,
      xbus_ack_i => xbus_ack,
      xbus_err_i => xbus_err,
      -- GPIO
      gpio_o     => gpio_o,
      gpio_i     => (others => '0'),
      -- coprocessor result interrupt -> CPU machine-external interrupt
      irq_mei_i  => aes_irq_s
    );

  aes_irq_o <= aes_irq_s;   -- also expose for observation

  -- ====================================================================
  -- Wishbone -> AXI4-Lite bridge
  -- ====================================================================
  bridge_inst : wb_to_axil
    port map (
      clk           => clk_i,
      rst_n         => rstn_i,
      wb_cyc_i      => xbus_cyc,
      wb_stb_i      => xbus_stb,
      wb_we_i       => xbus_we,
      wb_adr_i      => xbus_adr,
      wb_dat_i      => xbus_dat_w,
      wb_sel_i      => xbus_sel,
      wb_dat_o      => xbus_dat_r,
      wb_ack_o      => xbus_ack,
      wb_err_o      => xbus_err,
      m_axi_awaddr  => axi_awaddr,
      m_axi_awprot  => axi_awprot,
      m_axi_awvalid => axi_awvalid,
      m_axi_awready => axi_awready,
      m_axi_wdata   => axi_wdata,
      m_axi_wstrb   => axi_wstrb,
      m_axi_wvalid  => axi_wvalid,
      m_axi_wready  => axi_wready,
      m_axi_bresp   => axi_bresp,
      m_axi_bvalid  => axi_bvalid,
      m_axi_bready  => axi_bready,
      m_axi_araddr  => axi_araddr,
      m_axi_arprot  => axi_arprot,
      m_axi_arvalid => axi_arvalid,
      m_axi_arready => axi_arready,
      m_axi_rdata   => axi_rdata,
      m_axi_rresp   => axi_rresp,
      m_axi_rvalid  => axi_rvalid,
      m_axi_rready  => axi_rready
    );

  -- ====================================================================
  -- AES-128 coprocessor (wraps the 10-stage pipelined core)
  -- ====================================================================
  aes_inst : aes_coproc
    port map (
      clk           => clk_i,
      rst_n         => rstn_i,
      s_axi_awaddr  => axi_awaddr,
      s_axi_awprot  => axi_awprot,
      s_axi_awvalid => axi_awvalid,
      s_axi_awready => axi_awready,
      s_axi_wdata   => axi_wdata,
      s_axi_wstrb   => axi_wstrb,
      s_axi_wvalid  => axi_wvalid,
      s_axi_wready  => axi_wready,
      s_axi_bresp   => axi_bresp,
      s_axi_bvalid  => axi_bvalid,
      s_axi_bready  => axi_bready,
      s_axi_araddr  => axi_araddr,
      s_axi_arprot  => axi_arprot,
      s_axi_arvalid => axi_arvalid,
      s_axi_arready => axi_arready,
      s_axi_rdata   => axi_rdata,
      s_axi_rresp   => axi_rresp,
      s_axi_rvalid  => axi_rvalid,
      s_axi_rready  => axi_rready,
      irq           => aes_irq_s
    );

end architecture rtl;
