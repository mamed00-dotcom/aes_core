# Curated waveform for tb_neorv32_aes: the real NEORV32 CPU driving the AES.
# Sourced by run_neorv32_gui.sh (xsim -gui -tclbatch).
add_wave_divider "Clock / Reset / GPIO sentinel / IRQ line"
catch { add_wave /tb_neorv32_aes/clk }
catch { add_wave /tb_neorv32_aes/rstn }
catch { add_wave -radix hex /tb_neorv32_aes/gpio }
catch { add_wave /tb_neorv32_aes/aes_irq }

add_wave_divider "SoC internals: XBUS (Wishbone) + AXI4-Lite + IRQ"
catch { add_wave [get_objects -filter {type==signal} /tb_neorv32_aes/dut/*] }

add_wave_divider "Key expansion FSM"
catch { add_wave /tb_neorv32_aes/dut/aes_inst/u_core/key_load }
catch { add_wave -radix unsigned /tb_neorv32_aes/dut/aes_inst/u_core/kexp_cnt }
catch { add_wave /tb_neorv32_aes/dut/aes_inst/u_core/key_ready_r }

add_wave_divider "AES 10-stage pipeline"
catch { add_wave /tb_neorv32_aes/dut/aes_inst/inject }
catch { add_wave -radix bin /tb_neorv32_aes/dut/aes_inst/u_core/stage_valid }
catch { add_wave /tb_neorv32_aes/dut/aes_inst/u_core/out_valid }
catch { add_wave -radix hex /tb_neorv32_aes/dut/aes_inst/u_core/out_data }

run all
