#!/usr/bin/env perl
# by David Conrad
# This code is licensed under GPLv2 or later; go to gnu.org to read it
#  (not that it much matters for an asm preprocessor)
# usage: set your assembler to be something like "perl gas-preprocessor.pl gcc"
use strict;

my $debug = 0;

# Apple's gas is ancient and doesn't support modern preprocessing features like
# .rept and has ugly macro syntax, among other things. Thus, this script
# implements the subset of the gas preprocessor used by x264 and ffmpeg
# that isn't supported by Apple's gas.

my @gcc_cmd = @ARGV;
my @preprocess_c_cmd;

my $fix_unreq = $^O eq "darwin";

# new ffmpeg versions (from 2.4) uses gas-preprocessor as format:
#     gas-preprocessor -arch <arch> -as-type <as-type> -- $as
# to support armasm, etc.
#
# I don't have this requirement so I just ignore -arch and -as-type options  before -- to make it compatible
 
while ( @ARGV ) {
     my $option = shift;
     if ($option eq "-fix-unreq") {
        $fix_unreq = 1;
     } elsif ($option eq "-no-fix-unreq") {
        $fix_unreq = 0;
     }
     elsif ($option eq "--") {
        @gcc_cmd = @ARGV; 
        last;
     }
     # ignore other new options
     elsif ($option eq "-arch") {
        shift;
     }
     elsif ($option eq "-as-type") {
        shift;
     }
     else {
        shift;
     }
}


if (grep /\.c$/, @gcc_cmd) {
    # C file (inline asm?) - compile
    @preprocess_c_cmd = (@gcc_cmd, "-S");
} elsif (grep /\.[sS]$/, @gcc_cmd) {
    # asm file, just do C preprocessor
    @preprocess_c_cmd = (@gcc_cmd, "-E");
} 
elsif (grep /^-v$/, @gcc_cmd) {
    # -v: show version, for compiler tests.
    exit 0;
} else {
    die "Unrecognized input filetype";
}

# if compiling, avoid creating an output file named '-.o'
if ((grep /^-c$/, @gcc_cmd) && !(grep /^-o/, @gcc_cmd)) {
    foreach my $i (@gcc_cmd) {
        if ($i =~ /\.[csS]$/) {
            my $outputfile = $i;
            $outputfile =~ s/\.[csS]$/.o/;
            push(@gcc_cmd, "-o");
            push(@gcc_cmd, $outputfile);
            last;
        }
    }
}
@gcc_cmd = map { /\.[csS]$/ ? qw(-x assembler -) : $_ } @gcc_cmd;
@preprocess_c_cmd = map { /\.o$/ ? "-" : $_ } @preprocess_c_cmd;

my $comm;
my $is_arm64 = 0;

# detect architecture from gcc binary name
if ($gcc_cmd[0] =~ /arm/) {
    $comm = '@';
} elsif ($gcc_cmd[0] =~ /powerpc|ppc/) {
    $comm = '#';
}

# look for -arch flag
foreach my $i (1 .. $#gcc_cmd-1) {
    if ($gcc_cmd[$i] eq "-arch") {
        if ( $gcc_cmd[$i+1] =~ /arm64/ || $gcc_cmd[$i+1] =~ /aarch64/ ) {
            $comm = ';';
            $is_arm64 = 1;
        } elsif ($gcc_cmd[$i+1] =~ /arm/) {
            $comm = '@';
        } elsif ($gcc_cmd[$i+1] =~ /powerpc|ppc/) {
            $comm = '#';
        }
    }
}

# assume we're not cross-compiling if no -arch or the binary doesn't have the arch name
if (!$comm) {
    my $native_arch = qx/arch/;
    if ($native_arch =~ /arm64/ || $native_arch =~ /aarch64/) {
        $comm = ';';
        $is_arm64 = 1;
    } elsif ($native_arch =~ /arm/) {
        $comm = '@';
    } elsif ($native_arch =~ /powerpc|ppc/) {
        $comm = '#';
    }
}

if (!$comm) {
    die "Unable to identify target architecture";
}

my %ppc_spr = (ctr    => 9,
               vrsave => 256);

open(ASMFILE, "-|", @preprocess_c_cmd) || die "Error running preprocessor";

my $current_macro = '';
my $macro_level = 0;
my %macro_lines;
my %macro_args;
my %macro_args_default;

my $macro_executed_counter = 0;  # For \@ substitution 

my @pass1_lines;
my @ifstack;

# for .req and .unreq
my %register_aliases;

# pass 1: parse .macro
# note that the handling of arguments is probably overly permissive vs. gas
# but it should be the same for valid cases

debug_print("Pass 1\n");

while (<ASMFILE>) {

    debug_print("Read source line $_");

    # remove all comments (to avoid interfering with evaluating directives)
    s/(?<!\\)$comm.*//x;

    # comment out unsupported directives
    s/\.type/$comm.type/x;
    s/\.func/$comm.func/x;
    s/\.endfunc/$comm.endfunc/x;
    s/\.ltorg/$comm.ltorg/x;
    s/\.size/$comm.size/x;
    s/\.fpu/$comm.fpu/x;
    s/\.arch/$comm.arch/x;
    s/\.object_arch/$comm.object_arch/x;

    # the syntax for these is a little different
    s/\.global/.globl/x;
    # also catch .section .rodata since the equivalent to .const_data is .section __DATA,__const
    s/(.*)\.rodata/.const_data/x;
    s/\.int/.long/x;
    s/\.float/.single/x;

    # catch unknown section names that aren't mach-o style (with a comma)
    if (/.section ([^,]*)$/) {
        die ".section $1 unsupported; figure out the mach-o section name and add it";
    }

    parse_line($_);
}

# handle .if line. return 1 if the line is .if and handled, otherwise return 0
sub handle_if {
    my $line = $_[0];
    debug_print("handle_if: line = \"$line\"\n");

    #if ( $macro_level > 0 ) {
    #   return 0;
    #}

    # handle .if directives; apple's assembler doesn't support important non-basic ones
    # evaluating them is also needed to handle recursive macros
    if ($line =~ /\.if(n?)([a-z]*)\s+(.*)/) {
        my $result = $1 eq "n";
        my $type   = $2;
        my $expr   = $3;

        if ($type eq "b") {
            $expr =~ s/\s//g;
            $result ^= $expr eq "";
        } elsif ($type eq "c") {
            if ($expr =~ /(.*)\s*,\s*(.*)/) {
                $result ^= $1 eq $2;
            } else {
                die "argument to .ifc not recognized";
            }
        } elsif ($type eq "" || $type eq "e") {
            $result ^= eval_expr($expr) != 0;
        } elsif ($type eq "eq") {
            $result = eval_expr($expr) == 0;
        } elsif ($type eq "lt") {
            $result = eval_expr($expr) < 0;
        } elsif ($type eq "le") {
            $result = eval_expr($expr) <= 0;
        } elsif ($type eq "gt") {
            $result = eval_expr($expr) > 0;
        } elsif ($type eq "ge") {
            $result = eval_expr($expr) >= 0;
        } else {
	    chomp($line);
            die "unhandled .if varient. \"$line\"";
        }
        push (@ifstack, $result);
        return 1;
    } else {
        return 0;
    }
}

sub debug_print {
    if ( $debug ) {
       print @_[0];
    }
}

#
# Note those .macro may be wrapped inside .if conditional blocks, so it is moved to .if processing flow instead.
#
# So in pass1, we just read and put lines into pass1_lines
#
sub parse_line {

    my $line = @_[0];

    debug_print("Read line $line, then push to pass 1\n");

    push(@pass1_lines, $line)
}



close(ASMFILE) or exit 1;
#open(ASMFILE, "|-", @gcc_cmd) or die "Error running assembler";
#open(ASMFILE, ">/tmp/a.s") or die "Error running assembler";

my @sections;
my $num_repts;
my @rept_lines;
my $in_rept = 0;

my %literal_labels;     # for ldr <reg>, =<expr>
my $literal_num = 0;

my $in_irp = 0;
my @irp_args;
my $irp_param;

my @pass2_lines;

my %symbols;  # Store symbol used in .set, .altmacro and .noaltmacro
my $in_altmacro = 0;

sub eval_expr {
    my $expr = $_[0];
    debug_print("eval_expr: $expr\n");
    $expr =~ s/([A-Za-z._][A-Za-z0-9._]*)/$symbols{$1}/g;
    debug_print("eval_expr to: $expr\n");
    eval $expr;
}


# return 1 to output, 0 if handled
sub handle_macro {

    my $line = @_[0];

    debug_print("handle_macro: ".$line."\n");

    if ( $line =~ /\.macro/) {
        $macro_level++;
        debug_print("macro_level changed to $macro_level\n");
        if ($macro_level > 1 && !$current_macro) {
            die "nested macros but we don't have master macro";
        }
    } elsif ( $line =~ /\.endm/) {
        $macro_level--;
        debug_print("macro_level changed to $macro_level\n");
        if ($macro_level < 0) {
            die "unmatched .endm";
        } elsif ($macro_level == 0) {
            $current_macro = '';
            return 0;
        }
    }

    debug_print("macro_level = ".$macro_level.". ".$line."\n");

    if ($macro_level > 1) {

        debug_print("push ".$line." to macro ".$current_macro."\n");

        push(@{$macro_lines{$current_macro}}, $line);

        return 0;

    } elsif ($macro_level == 0) {

         debug_print("expand_macro\n");

         return expand_macros($line);
    } else {
        if ( $line =~ /\.macro\s+([\d\w\.]+)\s*(.*)/) {
            $current_macro = $1;

            # commas in the argument list are optional, so only use whitespace as the separator
            my $arglist = $2;
            $arglist =~ s/,/ /g;

            my @args = split(/\s+/, $arglist);
            foreach my $i (0 .. $#args) {
                my @argpair = split(/=/, $args[$i]);
                $macro_args{$current_macro}[$i] = $argpair[0];
                $argpair[0] =~ s/:vararg$//;
                $macro_args_default{$current_macro}{$argpair[0]} = $argpair[1];
            }
            # ensure %macro_lines has the macro name added as a key
            $macro_lines{$current_macro} = [];

            debug_print("start macro: $current_macro, args = $arglist\n");

        } elsif ($current_macro) {

            debug_print("push into macro: $current_macro\n");

            push(@{$macro_lines{$current_macro}}, $line);
        } else {
            die "macro level without a macro name";
        }
        
        return 0;
    }
}

# return 1 if output needed, 0 if handled
sub expand_macros {
    my $line = @_[0];

    debug_print("expand_macros: $line");

    # handle .if directives; apple's assembler doesn't support important non-basic ones
    # evaluating them is also needed to handle recursive macros
    #if (handle_if($line)) {
    #    return;
    #}

    if (/\.purgem\s+([\d\w\.]+)/) {
        delete $macro_lines{$1};
        delete $macro_args{$1};
        delete $macro_args_default{$1};
        return 0;
    }

    if ($line =~ /(\S+:|)\s*([\w\d\.]+)\s*(.*)/ && exists $macro_lines{$2}) {

        my $macro_executed_counter_in_this_scope = $macro_executed_counter++;

 
        debug_print("matched macro (".$2."). label (".$1."), counter $macro_executed_counter\n");

        debug_print("Output label ".$1."\n");
        print ASMFILE $1;

        # push(@pass3_lines, $1);

        my $macro = $2;

        # commas are optional here too, but are syntactically important because
        # parameters can be blank
        my @arglist = split(/,/, $3);
        my @args;
        my @args_seperator;

        my $comma_sep_required = 0;
        foreach (@arglist) {
            # allow for +, -, *, /, >>, and << in macro arguments
            $_ =~ s/\s*(\+|-|\*|\/|>>|<<)\s*/$1/g;

            my @whitespace_split = split(/\s+/, $_);
            if (!@whitespace_split) {
                push(@args, '');
                push(@args_seperator, '');
            } else {
                foreach (@whitespace_split) {
                        #print ("arglist = \"$_\"\n");
                    if (length($_)) {
                        push(@args, $_);
                        my $sep = $comma_sep_required ? "," : " ";
                        push(@args_seperator, $sep);
                        #print ("sep = \"$sep\", arg = \"$_\"\n");
                        $comma_sep_required = 0;
                    }
                }
            }

            $comma_sep_required = 1;
        }

        my %replacements;
        if ($macro_args_default{$macro}){
            %replacements = %{$macro_args_default{$macro}};
        }

        # construct hashtable of text to replace
        foreach my $i (0 .. $#args) {
            my $argname = $macro_args{$macro}[$i];
            my @macro_args = @{ $macro_args{$macro} };
            if ($args[$i] =~ m/=/) {
                # arg=val references the argument name
                # XXX: I'm not sure what the expected behaviour if a lot of
                # these are mixed with unnamed args
                my @named_arg = split(/=/, $args[$i]);
                $replacements{$named_arg[0]} = $named_arg[1];
            } elsif ($i > $#{$macro_args{$macro}}) {
                # more args given than the macro has named args
                # XXX: is vararg allowed on arguments before the last?
                $argname = $macro_args{$macro}[-1];
                if ($argname =~ s/:vararg$//) {
                    #print "macro = $macro, args[$i] = $args[$i], args_seperator=@args_seperator, argname = $argname, arglist[$i] = $arglist[$i], arglist = @arglist, args=@args, macro_args=@macro_args\n";
                    #$replacements{$argname} .= ", $args[$i]";
                    $replacements{$argname} .= "$args_seperator[$i] $args[$i]";
                } else {
                    die "Too many arguments to macro $macro";
                }
            } else {
                $argname =~ s/:vararg$//;
                $replacements{$argname} = $args[$i];
            }
        }

        # apply replacements as regex
        foreach (@{$macro_lines{$macro}}) {
            my $macro_line = $_;
            # do replacements by longest first, this avoids wrong replacement
            # when argument names are subsets of each other
            foreach (reverse sort {length $a <=> length $b} keys %replacements) {
                $macro_line =~ s/\\$_/$replacements{$_}/g;
            }
            $macro_line =~ s/\\\@/$macro_executed_counter_in_this_scope/g;       # replace \@
            $macro_line =~ s/\\\(\)//g;     # remove \()
            #parse_line($macro_line);

            debug_print("expand line: ".$macro_line."\n");

            #if ( handle_macro($macro_line) ) {
            #   print ASMFILE $macro_line;
            #}
            pass3_line($macro_line);

            #return 0;
        }
        return 0;
    }
    # .set directive
    elsif ( $line =~ /\.set\s+(.+)\s*,\s*(.+)/ ) {

        debug_print("set symbol $1 to $symbols{$1}\n");

	$symbols{$1} = eval_expr($2); 
        return 1;   
    }

    # .altmacro
    elsif ( $line =~ /.altmacro/ ) {
        $in_altmacro = 1;
        return 0;
    }
    
    # .noaltmacro
    elsif ( $line =~ /.noaltmacro/ ) {
        $in_altmacro = 0;
        return 0;

    # Others
    } else {
        #push(@pass1_lines, $line);
        debug_print("directly output: ".$line."\n");

        return 1;
    }

} # expand_macros

sub pass3_line {

    my $line = @_[0];

    debug_print("pass3_line: $line, macro_level = $macro_level\n");

    if ( $macro_level == 0 ) {

       if ( $in_altmacro ) {
          $line =~ s/\%([^,]*)/eval_expr($1)/eg if $in_altmacro;
          debug_print("in altmacro: ".$line);
       }

       # handle_if returns 1 if line is .if 
       if ( handle_if($line) ) {
          #chomp($line);
          debug_print("handled if. \"$line\" ifstack = @ifstack, scalar = ".scalar(@ifstack)."\n");
          next;
       }

       # In .if block
       if (scalar(@ifstack)) {
          if ($line =~ /\.endif/) {
             pop(@ifstack);
             debug_print("endif. ifstack = @ifstack\n");
             next; #return;
          } elsif ($line =~ /\.elseif\s+(.*)/) {
             if ($ifstack[-1] == 0) {
                $ifstack[-1] = !!eval_expr($1);
             } elsif ($ifstack[-1] > 0) {
                $ifstack[-1] = -$ifstack[-1];
             }
             next; #return;
          } elsif ($line =~ /\.else/) {
             $ifstack[-1] = !$ifstack[-1];
             next; #return;
          } elsif (handle_if($line)) {
             next; #return;
          }

          # discard lines in false .if blocks
          my $discard = 0;
          foreach my $i (0 .. $#ifstack) {
                  if ($ifstack[$i] <= 0) {
                     $discard = 1; 
                     last;
                  }
          }

          if ( $discard ) {
             next;
             #print ASMFILE $line;
          }

       } # in .if block 

       # Arrived here if in true if block or not in if block

       # clang's internal assembler doesn't support .req and .unreq, and in arm64, as uses clang's internal assembler.
       if ( $is_arm64 && $gcc_cmd[0] =~ /clang/ ) {
          # sym .req rn
          if ( $line =~ /([\w\d]+)\s+\.req\s+([\w\d]+)/ ) {
             $register_aliases{$1} = $2;
	     $line = $comm.$line;
          }

          # .unreq sym
          elsif ( $line =~ /\.unreq\s+([\w\d]+)/ ) {
             delete $register_aliases{$1};
             $line = $comm.$line;
          }

          # replace register alias
          else {
             foreach (keys %register_aliases) {
                my $alias = $_;
                my $register_name = $register_aliases{$alias};
                while (exists $register_aliases{$register_name}) {
                      $register_name = $register_aliases{$register_name};
                }
                $line =~ s/\b$alias\b/$register_name/g;
             }
          }
       }

       # special ldr <reg> =<expr> 
       $line = handle_special_insns($line);

    } # $macro_level == 0

    # macro?
    if ( handle_macro($line) ) {
       debug_print("handle_macro returned 1. Output ".$line);
       print ASMFILE $line;
    }

} # pass3_line 

sub handle_special_insns {

    my $line = @_[0];

    if ($line =~ /(.*)\s*ldr([\w\s\d]+)\s*,\s*=(.*)/) {
        my $label = $literal_labels{$3};
        if (!$label) {
            $label = ".Literal_$literal_num";
            #$label = "Literal_$literal_num";
            $literal_num++;
            $literal_labels{$3} = $label;
        }
        $line = "$1 ldr$2, $label\n";
    } elsif ($line =~ /\.ltorg/) {
        foreach my $literal (keys %literal_labels) {
            $line .= "$literal_labels{$literal}:\n .word $literal\n";
        }
        %literal_labels = ();
    } elsif ($line =~  /^(.*)\s*movi\s+(.*)\s*,\s*(#\d+)\s*\n*$/) {
        # Special case: 'movi vn.2d, #uimm64' and 'movi Dn, #uimm64'
        my $label = $1;
        my $reg = $2;
        my $imm = $3;
        if ( $reg =~ /([vV]\d+\.2[dD]|[dD]\d+)/ ) {
           $line = "$label movi $reg, $imm\n";
        }
        else {
           $line = "$label movi $reg, $imm, LSL #0\n";
        }
    }

    # adrp: gas uses "adrp <reg>, :pg_hi21:<label>", we need "adrp <reg>, <label>@PAGE"
    elsif ( $line =~ /^(.*)\s*adrp\s+(.*)\s*,\s*:pg_hi21:(.*)\s*/ ) {
        $line = "$1 adrp $2, $3\@PAGE\n";
    }
 
    # add: gas uses "add <reg>, :lo12:<label>", we need "add <reg>, <label>@PAGEOFF"
    elsif ( $line =~ /^(.*)\s*add\s+(.*)\s*,\s*:lo12:(.*)\s*/ ) {
        $line = "$1 add $2, $3\@PAGEOFF\n";
    }

    # Apple as doesn't accept 'mov Vd.<T>. vn.<T>'. Use alias 'ORR Vd.<T>, Vn.<T>, Vn.<T>' to replace
    elsif ( $line =~ /(.*)\s*mov\s+(v\d+\.(8|16)[bB])\s*,\s*(v\d+\.(8|16)[bB])\s*\n/ ) {
        $line = "$1 orr $2, $4, $4\n";
    }

    return $line;
}

# pass 2: parse .rept and .if variants
# NOTE: since we don't implement a proper parser, using .rept with a
# variable assigned from .set is not supported
#
# .if may contain variables from .macro or .irp or .rept, thus we have
# to put .if evaluation after all those things. - Holly Lee <holly.lee@gmail.com> June, 2012
debug_print("Pass 2:\n");

foreach my $line (@pass1_lines) {

    debug_print("Read pass 1 line: $line\n");

    # handle .previous (only with regard to .section not .subsection)
    if ($line =~ /\.(section|text|const_data)/) {
        push(@sections, $line);
    } elsif ($line =~ /\.previous/) {
        if (!$sections[-2]) {
            die ".previous without a previous section";
        }
        $line = $sections[-2];
        push(@sections, $line);
    }

    # The ldr <reg> =<expr> may expanded by macro, so move it to pass 3 - sub handle_ldr, returning $line

    # handle ldr <reg>, =<expr>
    #if ($line =~ /(.*)\s*ldr([\w\s\d]+)\s*,\s*=(.*)/) {
    #    my $label = $literal_labels{$3};
    #    if (!$label) {
    #        # $label = ".Literal_$literal_num";
    #        $label = "Literal_$literal_num";
    #        $literal_num++;
    #        $literal_labels{$3} = $label;
    #    }
    #    $line = "$1 ldr$2, $label\n";
    #} elsif ($line =~ /\.ltorg/) {
    #    foreach my $literal (keys %literal_labels) {
    #        $line .= "$literal_labels{$literal}:\n .word $literal\n";
    #    }
    #    %literal_labels = ();
    #}

    # @l -> lo16()  @ha -> ha16()
    $line =~ s/,\s+([^,]+)\@l\b/, lo16($1)/g;
    $line =~ s/,\s+([^,]+)\@ha\b/, ha16($1)/g;

    # move to/from SPR
    if ($line =~ /(\s+)(m[ft])([a-z]+)\s+(\w+)/ and exists $ppc_spr{$3}) {
        if ($2 eq 'mt') {
            $line = "$1${2}spr $ppc_spr{$3}, $4\n";
        } else {
            $line = "$1${2}spr $4, $ppc_spr{$3}\n";
        }
    }

    # old gas versions store upper and lower case names on .req,
    # but they remove only one on .unreq
    if ($fix_unreq) {
        if ($line =~ /^\s*\.unreq\s+(.*)/ ) {
            $line = ".unreq " . lc($1) . "\n";
            #print ASMFILE ".unreq " . uc($1) . "\n";
            push(@pass2_lines, ".unreq ".uc($1)."\n");
        }
    }

    if ($line =~ /\.rept\s+(.*)/) {
        if ( $in_rept || $in_irp ) {
           die "Sorry we didn't support nested .rept so far: $line\n";
        }

        $in_rept = 1;
        $num_repts = $1;
        #$rept_lines = "\n";
        @rept_lines = ();

        # handle the possibility of repeating another directive on the same line
        # .endr on the same line is not valid, I don't know if a non-directive is
        if ($num_repts =~ s/(\.\w+.*)//) {
            #$rept_lines .= "$1\n";
            push(@rept_lines, "$1\n");
        }
        $num_repts = eval($num_repts);
    } elsif ($line =~ /\.irp\s+([\d\w\.]+)\s*(.*)/) {
        if ( $in_irp || $in_rept ) {
           die "We cannot handle nested .irp : $line\n";
        }
        $in_irp = 1;
        $num_repts = 1;
        #$rept_lines = "\n";
        @rept_lines = ();
        $irp_param = $1;

        # only use whitespace as the separator
        my $irp_arglist = $2;
        $irp_arglist =~ s/,/ /g;
        $irp_arglist =~ s/^\s+//;
        @irp_args = split(/\s+/, $irp_arglist);
    } elsif ($line =~ /\.irpc\s+([\d\w\.]+)\s*(.*)/) {
        if ( $in_irp ) {
           die "We cannot handle nested .irpc\n";
        }
        $in_irp = 1;
        $num_repts = 1;
        #$rept_lines = "\n";
        @rept_lines = ();
        $irp_param = $1;

        my $irp_arglist = $2;
        $irp_arglist =~ s/,/ /g;
        $irp_arglist =~ s/^\s+//;
        @irp_args = split(//, $irp_arglist);
    } elsif ($line =~ /\.endr/) {
        if ($in_irp != 0) {
            foreach my $i (@irp_args) {
                #my $line = $rept_lines;
                foreach (@rept_lines) {
                   my $line = $_;
                   $line =~ s/\\$irp_param/$i/g;
                   $line =~ s/\\\(\)//g;     # remove \()
                   #print ASMFILE $line;
                   push(@pass2_lines, $line);
                }
            }
            $in_irp = 0;
            @irp_args = '';
        } elsif ( $in_rept ) {
            # print "endr rept: num_repts = $num_repts, rept_lines = @rept_lines\n";
            for (1 .. $num_repts) {
                #print ASMFILE $rept_lines;
                #push(@pass2_lines, $rept_lines);
                foreach (@rept_lines) {
                   my $line = $_;
                   # print "endr rept: push to pass2_lines: \"$line\"";
                   push(@pass2_lines, $line);
                }
            }
            #$rept_lines = '';
            @rept_lines = ();
            $in_rept = 0;
        }
        else {
            die "Unmatched .endr found\n";
        }
    # } elsif ($rept_lines) {
    } elsif ( $in_rept || $in_irp ) {
        #$rept_lines .= $line;
        # print "should be in rept: push to rept_lines: \"$line\"";
        push(@rept_lines, $line);
    } else {
        # print ASMFILE $line;
        # print "regular: push to pass2_lines: \"$line\"";
        debug_print("Write pass 2 line: $line\n");
        push(@pass2_lines, $line);
    }
}

# Pass3: handle .if directives

# Hacks for clang: clang in LLVM 3.1 in Xcode 4.3.x or later with -g options generates dwarf-2 debug information.
# It also pass -g to as but as -g doesn't support those debug directives created by clang -g.

if ( $gcc_cmd[0] =~ /clang$/ ) {
   @gcc_cmd = grep { $_ ne '-g' } @gcc_cmd;
}

if ( $debug ) {
   open(ASMFILE, ">/tmp/a.s") or die "Error running assembler";
}
else {
   open(ASMFILE, "|-", @gcc_cmd) or die "Error running assembler";
}

debug_print("Pass 3:\n");

foreach (@pass2_lines) {
    pass3_line($_);
}

print ASMFILE ".text\n";
foreach my $literal (keys %literal_labels) {
    print ASMFILE "$literal_labels{$literal}:\n .word $literal\n";
}

close(ASMFILE) or exit 1;
#exit 1
