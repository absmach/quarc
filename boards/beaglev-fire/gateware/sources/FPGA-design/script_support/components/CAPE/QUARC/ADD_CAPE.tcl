puts "======== Add cape option: QUARC ========"

#-------------------------------------------------------------------------------
# Import HDL source files
#-------------------------------------------------------------------------------
import_files -hdl_source {script_support/components/CAPE/QUARC/HDL/apb_quarc.v}
import_files -hdl_source {script_support/components/CAPE/QUARC/HDL/sha3.v}
import_files -hdl_source {script_support/components/CAPE/QUARC/HDL/ntt.v}
import_files -hdl_source {script_support/components/CAPE/QUARC/HDL/keccak.v}
import_files -hdl_source {script_support/components/CAPE/QUARC/HDL/keccak_engine.v}
import_files -hdl_source {script_support/components/CAPE/QUARC/HDL/CAPE.v}

build_design_hierarchy

create_hdl_core -file $project_dir/hdl/CAPE.v -module {CAPE} -library {work} -package {}

hdl_core_add_bif -hdl_core_name {CAPE} -bif_definition {APB:AMBA:AMBA2:slave} -bif_name {BIF_1} -signal_map {} 
hdl_core_assign_bif_signal -hdl_core_name {CAPE} -bif_name {BIF_1} -bif_signal_name {PADDR} -core_signal_name {APB_SLAVE_SLAVE_PADDR} 
hdl_core_assign_bif_signal -hdl_core_name {CAPE} -bif_name {BIF_1} -bif_signal_name {PSELx} -core_signal_name {APB_SLAVE_SLAVE_PSEL} 
hdl_core_assign_bif_signal -hdl_core_name {CAPE} -bif_name {BIF_1} -bif_signal_name {PENABLE} -core_signal_name {APB_SLAVE_SLAVE_PENABLE} 
hdl_core_assign_bif_signal -hdl_core_name {CAPE} -bif_name {BIF_1} -bif_signal_name {PWRITE} -core_signal_name {APB_SLAVE_SLAVE_PWRITE} 
hdl_core_assign_bif_signal -hdl_core_name {CAPE} -bif_name {BIF_1} -bif_signal_name {PRDATA} -core_signal_name {APB_SLAVE_SLAVE_PRDATA} 
hdl_core_assign_bif_signal -hdl_core_name {CAPE} -bif_name {BIF_1} -bif_signal_name {PWDATA} -core_signal_name {APB_SLAVE_SLAVE_PWDATA} 
hdl_core_rename_bif -hdl_core_name {CAPE} -current_bif_name {BIF_1} -new_bif_name {APB_TARGET} 

#-------------------------------------------------------------------------------
# Build the Cape module
#-------------------------------------------------------------------------------
set sd_name ${top_level_name}

#-------------------------------------------------------------------------------
# Instantiate.
#-------------------------------------------------------------------------------
sd_instantiate_hdl_core -sd_name ${sd_name} -hdl_core_name {CAPE} -instance_name {CAPE} 

#-------------------------------------------------------------------------------
# Connections.
#-------------------------------------------------------------------------------

# Clocks and resets
sd_connect_pins -sd_name ${sd_name} -pin_names {"CLOCKS_AND_RESETS:FIC_3_PCLK" "CAPE:PCLK"}
sd_connect_pins -sd_name ${sd_name} -pin_names {"CLOCKS_AND_RESETS:FIC_3_FABRIC_RESET_N" "CAPE:PRESETN" }

# APB target window (FIC3, base 0x4110_0000)
sd_connect_pins -sd_name ${sd_name} -pin_names {"CAPE:APB_TARGET" "BVF_RISCV_SUBSYSTEM:CAPE_APB_MTARGET"}

# The Quarc cape uses no cape-header I/O, GPIO, or fabric interrupts.
sd_connect_pins_to_constant -sd_name ${sd_name} -pin_names {BVF_RISCV_SUBSYSTEM:GPIO_2_F2M} -value {GND} 
sd_mark_pins_unused -sd_name ${sd_name} -pin_names {BVF_RISCV_SUBSYSTEM:GPIO_2_M2F} 
sd_mark_pins_unused -sd_name ${sd_name} -pin_names {BVF_RISCV_SUBSYSTEM:GPIO_2_OE_M2F} 

sd_clear_pin_attributes -sd_name ${sd_name} -pin_names {BVF_RISCV_SUBSYSTEM:MSS_INT_F2M_A} 
sd_clear_pin_attributes -sd_name ${sd_name} -pin_names {BVF_RISCV_SUBSYSTEM:MSS_INT_F2M_B} 
sd_clear_pin_attributes -sd_name ${sd_name} -pin_names {BVF_RISCV_SUBSYSTEM:MSS_INT_F2M_C} 
sd_mark_pins_unused -sd_name ${sd_name} -pin_names {BVF_RISCV_SUBSYSTEM:MSS_INT_F2M_A} 
sd_mark_pins_unused -sd_name ${sd_name} -pin_names {BVF_RISCV_SUBSYSTEM:MSS_INT_F2M_B} 
sd_mark_pins_unused -sd_name ${sd_name} -pin_names {BVF_RISCV_SUBSYSTEM:MSS_INT_F2M_C} 

sd_mark_pins_unused -sd_name ${sd_name} -pin_names {BVF_RISCV_SUBSYSTEM:MMUART_4_TXD} 
sd_connect_pins_to_constant -sd_name ${sd_name} -pin_names {BVF_RISCV_SUBSYSTEM:MMUART_4_RXD} -value {GND} 
