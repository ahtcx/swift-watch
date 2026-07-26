SECTIONS {
	/DISCARD/ : { *(.swift_modhash*) }
}
INSERT AFTER .text;
