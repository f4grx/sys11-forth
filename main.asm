/* Mini forth interpreter based on eForth with simplifications

   Data structures
   ===============

   Dictionary and Data space
   -------------------------

   The data space is used to store new word definitions and user data.
   It grows from low addresses to upper addresses in the external memory.

   Builtin words are stored in RODATA. They cant be changed, but can be
   overriden by user entries. Builtin entries do no have parameter fields.

   User definitions are allocated in the data space. The definitions are added
   one after the other, linking the new one to the previous one. The pointer to
   the last definition is maintained in LAST. The first user word points to the last
   entry in the builtin list. This allows overriding of any built-in word.

   Data is allocated in an incremental fashion starting from the lowest
   address. at any time, the HERE variable contains the address of the next
   free zone.

   Dictionary entry
   ----------------

   Each entry has the following structure:
   N bytes: the word itself, null terminated.
   1 byte:  flags (if necessary, this field will not be used initially)
   2 bytes: pointer to previous entry
   2 bytes: code pointer (ITC).
            ENTER:   execute a list of forth opcodes stored after this pointer.
            DOCONST: push the value of the stored constant
            DOVAR:   push the address of the named constant
            other:   native code implementation
   
   Parameter stack
   ---------------
   The parameter stack is used to store temporary data items. It shoud not grow
   to an extremely large value, so it size is fixed when the interpreter is
   initialized.
   The stack grows down, it starts at the end of the RAM, and the storage
   address decreases on PUSH and increases on POP.
   For the moment underflow and overflows are not detected.

   Return stack
   ------------
   The return stack is used to push return addresses when nesting word
   executions. It is also used to manage control flow structures. Since this
   space is used a lot by complex programs, it is expected that limiting its
   size might prevent large programs from executing. Its size is only limited
   by the growth of the data space. It is initialized just below the maximum
   span of the parameter stack, and it can grows down until the return stack
   pointer hits HERE, the next allocation address in the data space.

   Registers
   ---------
   The forth interpreter uses registers for its internal use.
   SP is used as parameter stack pointer.
   Y  is used as return stack pointer.
   X and D can be used for calculations.
   a data word (IP) is used as instruction pointer.
   This is inspired by eForth (https://github.com/tonypdmtr/eForth/blob/master/hc11e4th.asm)

   To pop from return stack, we increment Y by 2 with ldab #2 aby then load at 0,y
   To push to the return stack, we store at 0,Y then dey dey
   The data stack can use the hc11 push and pulls.

   Interpreter
   -----------
   The intepreter receives chars from the input device until an end of line is
   reached. The compiler is then executed, which translates input to an unnamed
   word. The unnamed word is then executed.

   Compilation
   -----------
   Each word is recognized and replaced by the address of its code pointer.
   Note this is not the address of the definition but the code pointer itself.
   The last code pointer entry of a compiled word is a RETURN, which pops an
   address from the return stack and use it as new instruction pointer.

   The compiler uses all the CPU registers, so the previous contents of the
   forth registers is saved before compilation and restored after.

*/

	/* Serial definitions */
	.equ BAUD , 0x2B
	.equ SCCR1, 0x2C
	.equ SCCR2, 0x2D
	.equ SCSR , 0x2E
	.equ SCDR , 0x2F
	.equ SCSR_RDRF     ,0x20 /* Receive buffer full */
	.equ SCSR_TDRE     ,0x80 /* Transmit buffer empty */


	/* Forth config */
	.equ	IBUF_LEN, 80

	/* Define variables in internal HC11 RAM */
	.data
IP:	.word	0		/* Instruction pointer */

	/* Input text buffering */

IBUF:	.space	IBUF_LEN	/* Input buffer */
ILEN:	.word	0		/* Number of characters in current line */
IN:	.word	0		/* Parse position in the input buffer */
BASE:	.word	0		/* Value of the base used for number parsing */
LAST:	.word	0		/* Pointer to the last defined word or name */

	.text

/*===========================================================================*/
/* Structure of a compiled word: We have a suite of code pointers. Each code pointer has to be executed in turn. */
/* The last code pointer of the list has to be "exit", which returns to the caller. */
/* +---+-------+------+------+------+-----+------+ */
/* |HDR| ENTER | PTR1 | PTR2 | PTR3 | ... | EXIT | */
/* +---+-------+------+------+------+-----+------+ */
/*                ^      ^            */
/*                IP    nxtIP=IP+2     */

	.globl PUSHD
PUSHD:
	psha			/* We can use this instead of next to push a result before ending a word */
	pshb
NEXT:
	ldx	*IP		/* Get the instruction pointer */
NEXT2:				/* We can call here if X already has the value for IP */
	inx			/* Increment IP to look at next word */
	inx
	stx	*IP		/* IP+1->IP Save IP for next execution */
	dex			/* Redecrement, because we need the original IP */
	dex
	ldx	0,X		/* (IP)->W Deref: This IP contains a code pointer */
	jmp	0,X		/* JMP (W) */

/*===========================================================================*/
/* Starts execution of a compiled word. The current IP is pushed on the return stack, then we jump */
ENTER:
	ldx	*IP
	dey			/* Pre-Decrement Y by 2 to push */
	dey
	stx	0,Y		/* Push the next IP to be executed after return from this thread */
	bra	NEXT2		/* Manage text opcode address */
	
/*===========================================================================*/
/* Exit ends the execution of a word. The previous IP is on the return stack, so we pull it */
EXIT:
	ldx	0,Y		/* Get previous value for IP from top of return stack */
	ldab	#2
	aby			/* Increment Y by 2 to pop */
	bra	NEXT2		

/*===========================================================================*/
/* Do litteral: Next cell in thread is a litteral value to be pushed. */
DOLIT:
	ldx	*IP		/* Get the instruction pointer */
	ldd	0,X
	inx			/* Increment IP to look at next word */
	inx
	stx	*IP		/* IP+1->IP Save IP for next execution */
	bra	PUSHD

/*===========================================================================*/
/* Next word contains an address that will be pushed on the param stack */
DOVAR:

/*===========================================================================*/
/* Next word contains an address that will be pushed on the param stack */
DOCONST:
	
/*===========================================================================*/
/* Native words */
/*===========================================================================*/

/* Internal opcodes generated by compiler for loop management */
code_BRANCH:
code_QBRANCH:
code_NEXT:
	bra	NEXT

/*===========================================================================*/
	.section .rodata
word_EMIT:
	.asciz	"EMIT"
	.word	0
	.word	code_KEY

	.text
code_EMIT:
	pulb
	pula
.Lemit2:
	brclr	*SCSR #SCSR_TDRE, .Lemit2
	stab	*SCDR
	bra	NEXT

/*===========================================================================*/
	.section .rodata
word_KEY:
	.asciz	"KEY"
	.word	word_EMIT
	.word	code_KEY

	.text
code_KEY:
	brclr	*SCSR #SCSR_RDRF, code_KEY
	ldab	*SCDR
	clra
	bra	PUSHD

/*===========================================================================*/
	.section .rodata
word_STORE:
	.asciz	"!"
	.word	word_KEY
	.word	code_STORE

	.text
code_STORE:
	pulx
	pulb
	pula
	std	0,X
	bra	NEXT

/*===========================================================================*/
	.section .rodata
word_LOAD:
	.asciz "@"
	.word	word_STORE
	.word	code_LOAD

	.text
code_LOAD:
	pulx
	ldd	0,X
	bra	PUSHD

/*===========================================================================*/
	.section .rodata
word_DUP:
	.asciz "DUP"
	.word	word_STORE
	.word	code_DUP

	.text
code_DUP:
	tsx			/* Get stack pointer in X */
	ldd	0,X		/* Load top of stack in D */
	bra	NEXT2		/* This will push top of stack again */


/*===========================================================================*/
	.section .rodata
word_ACCEPT:
	.asciz "ACCEPT"
	.word	word_DUP
code_ACCEPT:
	.word	ENTER
	.word	EXIT

/*===========================================================================*/
/* Main forth interactive interpreter loop */
	.section .rodata
word_QUIT:
	.asciz "QUIT"
	.word	word_ACCEPT
code_QUIT:
	.word	ENTER
QUIT2:
	.word	DOLIT, IBUF
	.word	DOLIT, IBUF_LEN
	.word	code_ACCEPT
	.word	code_BRANCH, QUIT2

	.text
/*===========================================================================*/
	.globl _start
_start:

	/* Init serial port */

	ldaa	#0x30
	staa	BAUD
	ldaa	#0x0C
	staa	SCCR2

	/* Init default values */
	ldx	#10
	stx	*BASE

	ldx	#word_QUIT
	stx	*LAST

	/* Setup the runtime environment */

	lds	#0x8000		/* Parameter stack at end of RAM */
	ldy	#0x7C00		/* Return stack 1K before end of RAM */
	ldx	#code_QUIT	/* load pointer to startup code */
	bra	NEXT2		/* Start execution */

