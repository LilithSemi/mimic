# Declarative build targets. FPGA entries produce generated IP and a bitstream.
# PDK entries produce generated ASIC IP for a later tapeout flow.
{
  mimic-ip,
  sky130-pdk ? null,
  gf180mcu-pdk ? null,
}:
{
  orangecrab-25f = {
    kind = "fpga";
    ip = mimic-ip.mkDevice {
      name = "mimic-orangecrab-25f";
      board = "orangecrab-25f";
    };
  };

  sky130-hd = {
    kind = "pdk";
    ip = mimic-ip.mkDevice {
      name = "mimic-sky130-hd";
      target = "sky130:hd";
      pdkRoot = "${sky130-pdk}/${sky130-pdk.pdkPath}";
    };
    pdk = sky130-pdk;
  };

  gf180mcu-3v3 = {
    kind = "pdk";
    ip = mimic-ip.mkDevice {
      name = "mimic-gf180mcu-3v3";
      target = "gf180mcu:3v3";
      pdkRoot = "${gf180mcu-pdk}/${gf180mcu-pdk.pdkPath}";
    };
    pdk = gf180mcu-pdk;
  };
}
