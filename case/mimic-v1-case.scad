// Mimic V1 case: tray, lid and ZIF end cap.
//
// Frame: the board top is z = 0, the ZIF end is x = 0 and the USB-C end is
// x = board_l, y runs across the board. All sizes are in mm.
//
// Render one part with -D 'part="tray"' (or "lid", "cap", "assembly",
// "exploded"). Give the board model with -D 'board="path/to/board.stl"' to
// see the fit; the model comes from `kicad-cli pcb export stl`. Give
// -D 'print=true' to put a single part flat on the bed for printing.

part = "assembly";
board = "";
print = false;
font = "Liberation Sans:style=Bold";

$fn = 48;

// Board.
board_l = 42.0;
board_w = 23.0;
board_t = 1.6;

// Clearances around the board and its parts.
gap = 0.25;
top_room = 4.0;     // tallest top part is the USB-C at 3.3 mm
bottom_room = 1.6;  // bottom parts are 0.8 mm or less
wall = 1.2;
fit = 0.2;          // print clearance between mating parts

// The end cap covers the ZIF and its latch.
cap_x = 9.0;

// Outer box.
x0 = -wall - gap;
x1 = board_l + 1.0;  // USB-C face sits 1.0 mm behind the outer face
y0 = -wall - gap;
y1 = board_w + gap + wall;
z0 = -board_t - bottom_room - wall;
z1 = top_room + wall;

// The tray is a plate as wide as the inside of the lid walls.
plate_t = wall;

// Openings.
usb_y = 12.0;
usb_w = 9.8;
usb_h = 4.0;
usb_z = 1.6;
ffc_y = 12.0;
ffc_w = 9.6;
ffc_h = 1.2;
ffc_z = 1.0;
led_x = 21.0;
led_y = 21.5;
led_d = 1.6;

// Snap ridges on the plate edge, grooves in the walls.
ridge = 0.3;

module rounded_box(p0, p1, r = 1.0) {
    translate(p0 + [r, r, 0])
        minkowski() {
            cube([p1[0] - p0[0] - 2 * r, p1[1] - p0[1] - 2 * r, p1[2] - p0[2] - 0.01]);
            cylinder(r = r, h = 0.01);
        }
}

module rounded_rect(w, h, r) {
    offset(r = r) square([w - 2 * r, h - 2 * r], center = true);
}

// The inside of the walls, which the plate fills.
in_x0 = x0 + wall;
in_x1 = x1 - wall;
in_y0 = y0 + wall;
in_y1 = y1 - wall;

module tray() {
    // Plate.
    translate([in_x0 + fit, in_y0 + fit, z0])
        cube([in_x1 - in_x0 - 2 * fit, in_y1 - in_y0 - 2 * fit, plate_t]);
    // Snap ridges along both long edges.
    for (y = [in_y0 + fit, in_y1 - fit])
        translate([in_x0 + 3, y, z0 + plate_t / 2])
            rotate([0, 90, 0]) cylinder(r = ridge, h = in_x1 - in_x0 - 6);
    // Ribs under the long board edges. The board rests on them.
    for (y = [-gap + fit, board_w - 0.6])
        translate([0.5, y, z0 + plate_t])
            cube([board_l - 1.0, 0.6 + gap - fit, -board_t - (z0 + plate_t)]);
}

module shell(xa, xb, left_wall, right_wall) {
    difference() {
        rounded_box([xa, y0, z0], [xb, y1, z1]);
        // Hollow.
        translate([left_wall ? xa + wall : xa - 1, in_y0, z0 - 1])
            cube([(right_wall ? xb - wall : xb + 1) - (left_wall ? xa + wall : xa - 1), in_y1 - in_y0, z1 - wall - z0 + 1]);
        // Grooves for the plate ridges.
        for (y = [in_y0, in_y1])
            translate([left_wall ? xa + wall : xa - 1, y, z0 + plate_t / 2])
                rotate([0, 90, 0])
                    cylinder(r = ridge + fit / 2, h = (right_wall ? xb - wall : xb + 1) - (left_wall ? xa + wall : xa - 1));
    }
    // Ribs that hold the board edges down.
    for (y = [-gap, board_w - 0.5 + gap])
        translate([xa + (left_wall ? wall : 0) + 0.5, y, 0])
            cube([xb - xa - (left_wall ? wall : 0) - (right_wall ? wall : 0) - 1.0, 0.5, z1 - wall]);
}

module lid() {
    difference() {
        shell(cap_x + fit / 2, x1, false, true);
        // USB-C.
        translate([x1 - wall - 0.5, usb_y, usb_z])
            rotate([90, 0, 90]) linear_extrude(wall + 1) rounded_rect(usb_w, usb_h, 1.4);
        // LED.
        translate([led_x, led_y, z1 - wall - 0.5]) cylinder(d = led_d, h = wall + 1);
        // Name.
        translate([31, 12, z1 - 0.4]) linear_extrude(0.5)
            text("Mimic", size = 4, font = font, halign = "center", valign = "center");
    }
}

module cap() {
    difference() {
        shell(x0, cap_x - fit / 2, true, false);
        // FFC slot.
        translate([x0 - 0.5, ffc_y, ffc_z])
            rotate([90, 0, 90]) linear_extrude(wall + 1) rounded_rect(ffc_w, ffc_h, 0.4);
        // Fingernail notch at the seam, on top.
        translate([cap_x - fit / 2, board_w / 2, z1])
            rotate([90, 0, 0]) cylinder(r = 0.8, h = 8, center = true);
    }
    // Strain relief: a rib inside the slot that pinches the cable lightly.
    translate([x0 + wall, ffc_y - ffc_w / 2, ffc_z + ffc_h / 2 - 0.1])
        cube([1.5, ffc_w, 0.25]);
}

module board_model() {
    if (board != "")
        color("darkgreen") translate([0, board_w, 0]) import(board);
}

// The tray prints on its plate. The lid and the cap print on their top face,
// so the walls need no support.
module on_top_face() {
    if (print) translate([0, 0, z1]) rotate([180, 0, 0]) children();
    else children();
}

if (part == "tray") translate([0, 0, print ? -z0 : 0]) tray();
if (part == "lid") on_top_face() lid();
if (part == "cap") on_top_face() cap();
if (part == "assembly") {
    color("dimgray") tray();
    color("silver", 0.55) lid();
    color("gainsboro", 0.55) cap();
    board_model();
}
if (part == "closed") {
    color("dimgray") tray();
    color("silver") lid();
    color("gainsboro") cap();
}
// Cut through the middle of the USB-C to show how the board sits.
if (part == "section") {
    difference() {
        union() {
            color("dimgray") tray();
            color("silver") lid();
            color("gainsboro") cap();
        }
        translate([x0 - 1, usb_y, z0 - 1]) cube([x1 - x0 + 2, y1, z1 - z0 + 2]);
    }
    intersection() {
        board_model();
        translate([x0 - 1, y0 - 1, z0 - 1]) cube([x1 - x0 + 2, usb_y - y0 + 1, z1 - z0 + 2]);
    }
}
// The cap pulled off: the ZIF latch is open to reach.
if (part == "cap_off") {
    color("dimgray") tray();
    color("silver") lid();
    board_model();
    color("gainsboro") translate([-14, 0, 0]) cap();
}
if (part == "exploded") {
    color("dimgray") tray();
    translate([0, 0, 6]) board_model();
    color("silver") translate([0, 0, 16]) lid();
    color("gainsboro") translate([-8, 0, 16]) cap();
}
