--!strict
-- Original interactive homebrew. Hold GBA buttons to change the screen colour.
-- Generated in memory: no external ROM, BIOS, assets or network access required.
local DemoROM = {}
function DemoROM.create(): buffer
	local rom = buffer.create(0x8000)
	buffer.writeu32(rom, 0, 0xEA00002E) -- branch past header
	local code = {
		0xE59F0038, -- ldr r0, =DISPCNT
		0xE59F1038, -- ldr r1, =mode3
		0xE1C010B0, -- strh r1, [r0]
		0xE59F5034, -- ldr r5, =KEYINPUT
		0xE59F6034, -- ldr r6, =keymask
		0xE1D530B0, -- poll: ldrh r3,[r5]
		0xE1E03003, -- mvn r3,r3
		0xE0033006, -- and r3,r3,r6
		0xE3530000, -- cmp r3,0
		0x059F3024, -- ldreq r3,=default colour
		0xE59F2024, -- ldr r2,=VRAM
		0xE59F4024, -- ldr r4,=pixel count
		0xE0C230B2, -- fill: strh r3,[r2],2
		0xE2544001, -- subs r4,r4,1
		0x1AFFFFFC, -- bne fill
		0xEAFFFFF4, -- b poll
	}
	local pool = {0x04000000, 0x0403, 0x04000130, 0x3FF, 0x2F23, 0x06000000, 240 * 160}
	for i, word in code do buffer.writeu32(rom, 0xC0 + (i - 1) * 4, word) end
	for i, word in pool do buffer.writeu32(rom, 0xC0 + #code * 4 + (i - 1) * 4, word) end
	buffer.writestring(rom, 0xA0, "DEPTH DEMO")
	buffer.writestring(rom, 0xAC, "DDEM01")
	buffer.writeu8(rom, 0xB2, 0x96)
	local checksum = -0x19
	for i = 0xA0, 0xBC do checksum -= buffer.readu8(rom, i) end
	buffer.writeu8(rom, 0xBD, checksum % 256)
	return rom
end
return DemoROM
