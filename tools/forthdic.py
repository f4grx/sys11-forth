#!/usr/bin/env python3
#this tools displays the contents of the .dict section inside my forth interpreter.

import sys
import elffile
import struct

#------------------------------------------------------------------------------
#this set of classes are helper that follow the structure of the elffile library
class ElfSymbolEntry(elffile.StructBase):
    nameoffset = None #Elf32_Word(4)
    name = None #found separately
    value = None #Elf32_Addr(4)
    size = None #Elf32_Word(4)
    info = None #unsigned char(1)
    other = None #unsigned char(1)
    shndx = None #Elf32_Half(2)

    def unpack_from(self, section, offset=0):
        (self.nameoffset, self.value, self.size, self.info,
         self.other, self.shndx ) = self.coder.unpack_from(section, offset)
        return self

    def pack_into(self, section, offset=0):
        self.coder.pack_into(section, offset,
                             self.nameoffset, self.value, self.size, self.info,
                             self.other, self.shndx)
        return self

    def __repr__(self):
        return ('<{0}@{1}: nameoffset={2}, name=\'{8}\' value={3}, size={4}, info={5}, other={6}, shndx={7}>'
                .format(self.__class__.__name__, hex(id(self)), self.nameoffset, "%08X"%self.value, self.size, self.info, self.other, self.shndx, self.name))

    def findname(self, strtab):
        if self.nameoffset == 0:
            self.name = ''
        else:
            strcontents = strtab.content
            self.name = strcontents[self.nameoffset:strcontents.find(b'\0', self.nameoffset)]
        return self

#subclass for bigendian (unused)
class ElfSymbolEntryl(ElfSymbolEntry):
    coder = struct.Struct(b'<IIIBBH')

#subclass for little endian
class ElfSymbolEntryb(ElfSymbolEntry):
    coder = struct.Struct(b'>IIIBBH')

#------------------------------------------------------------------------------

dot = False
try:
    src = sys.argv[1]
    if src == '-dot':
        dot = True
        src = sys.argv[2]
    elf = elffile.open(src)

except Exception as e:
    print("ERROR : Could not open input file '", file_input,"'")
    print(e)
    sys.exit(1)

rodata  = None
dicdata = None
symbols = None
strings = None

for sec in elf.sectionHeaders:
    if sec.name == b".rodata":
        print("    .rodata found")
        rodata = sec
    elif sec.name == b".dic":
        print("    .dic found")
        dicdata = sec
    elif sec.name == b".symtab":
        symbols = sec
        print("    Symbol table found, %u bytes" % len(symbols.content))
    elif sec.name == b".strtab":
        print("    Strings table found")
        strings = sec

if strings == None:
    strings = elf.sectionHeaders[elf.fileHeader.shstrndx]
    print("    ! Found string table via file header, this part of the code seems buggy")

#create the list of all symbols
syms = []
if symbols != None:
    symcount = int(len(symbols.content) / 16)
    for i in range(symcount):
        s = ElfSymbolEntryb().unpack_from(symbols.content, i*16).findname(strings)
        syms.append(s)

def findsymaddr(name):
    for s in syms:
        if s.name == name:
            return s.value

    return None

def findsymname(addr):
    if addr == 0:
        return "NULL"

    for s in syms:
        if s.value == addr:
            if len(s.name) == 0: continue
            return s.name

    return "None@%04X" % addr

def parse_pstring(buf,off,mask=0xFF):
    strlen = buf[off] & mask
    off += 1
    s = ""
    for i in range(strlen):
        s = s + chr(buf[off])
        off += 1
    return s

#------------------------------------------------------------------------------
if rodata == None:
    print("No dic found")
    sys.exit(0)

dicstart  = findsymaddr(b"__DEBUG__DICSTART__")
dicend    = findsymaddr(b"__DEBUG__DICEND__")
adrenter  = findsymaddr(b"code_ENTER")
adrexit   = findsymaddr(b"RETURN")
adrimm    = findsymaddr(b"IMM")
adrimmstr = findsymaddr(b"IMMSTR")
adrshowstr= findsymaddr(b"SHOWSTR")
adrabortnz= findsymaddr(b"ABORTNZ")
adrcompile= findsymaddr(b"COMPILE_IMM")

print("ENTER=%04X EXIT=%04X IMM=%04X IMMSTR=%04X" % (adrenter,adrexit,adrimm,adrimmstr))
print("start=%04X end=%04X" % (dicstart,dicend))

base = dicdata.addr
off  = dicstart - base
cnt = dicdata.content
length = dicend - dicstart
print("rodata size: ", len(cnt))
print("dic size: ", length, "at offset", off)
for i in range(length):
    if i%16==0: print("%04X: "%i, end='')
    print("%02X" % cnt[i+off], end='')
    if i%16==15: print()
print()

if dot:
    words = open("words.txt", "wb")
    graph = open("words.gv", "wb")
    graph.write(b"strict digraph words {\n")
    gr = dict()

ptr  = off
has_header = True
while ptr < off+length:

    if has_header:
        lnk = struct.Struct(">H").unpack_from(cnt, ptr)[0]
        if lnk == adrenter:
            #surprise: prev link is a code_ENTER. We found a headerless word
            has_header = False
            continue

        print()
        wordstart = ptr+base
        print("[%04X] " % (ptr+base), end='')
        ptr += 2
        print("prev=%04X" % lnk, findsymname(lnk) )

        print("[%04X] " % (ptr+base), end='')
        name = parse_pstring(cnt,ptr,0x3F)
        ptr += 1+len(name)
        internalname = findsymname(ptr+base).decode()
        print("name=%s" % name, "(%s)" % internalname, "flags=%02X" % (cnt[ptr] & 0xC0))
        if dot:
            words.write(name.encode())
            words.write(b"\n")

    else:
        #Unnamed word (only used in compiling structures)
        has_header = True #restore behaviour for next word
        print()
        print("[%04X] " % (ptr+base), end='')
        internalname = findsymname(ptr+base).decode()
        print("Unnamed word (%s)" % internalname)

    print("[%04X] " % (ptr+base), end='')
    code = struct.Struct(">H").unpack_from(cnt, ptr)
    code = code[0]
    ptr += 2
    print("  code=%04X" % code, findsymname(code) )

    if code != adrenter:
        if dot:
            graph.write(("\"%s\" [shape=box]\n"%internalname).encode())
        continue

    #we have a wordlist. display words
    word = 0
    prevname = ""
    prev = 0
    while (ptr+base) < dicend:
        word = struct.Struct(">H").unpack_from(cnt, ptr)[0]
        if word == wordstart and prev != adrcompile:
            break #we found the PREV link of the next word
        if word == adrenter and prev != adrcompile:
            has_header = False #next word does not have a header
            break

        print("[%04X] " % (ptr+base), end='')
        wordname = findsymname(word).decode()
        print("    %04X" % word, wordname)
        if dot and not(prevname=='BRANCH' or prevname=='BRANCHZ' or prevname=='JNZD') and not(wordname=='RETURN' or wordname=='IMM' or wordname=='BRANCH' or wordname=='BRANCHZ'):
            edge = "\"%s\" -> \"%s\""%(internalname,wordname)
            gr[edge] = True
        ptr += 2
        prevname = wordname

        if word == adrimm:
            print("[%04X] " % (ptr+base), end='')
            imm = struct.Struct(">H").unpack_from(cnt, ptr)[0]
            ptr += 2
            if imm >= dicstart and imm < dicend:
                print("    %04X" % imm, findsymname(imm) )
            else:
                print("    %04X" % imm )
        elif ((word == adrimmstr) or (word==adrabortnz) or (word==adrshowstr)) and (prev!=adrcompile):
            print("[%04X] " % (ptr+base), end='')
            immstr = parse_pstring(cnt,ptr)
            strlen = len(immstr)
            ptr += 1 + strlen
            print("    (len=",strlen,") '",immstr,"'", sep='' )

        prev = word

if dot:
    words.close()
    for x in gr:
        graph.write(x.encode())
        graph.write(b"\n")
    graph.write(b"}\n")
    graph.close()

