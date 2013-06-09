#!/bin/bash

# Auteur : KAAM Gabriel SRT-2
# Projet : LO14 Printemps 2012
# Sujet  : Synchroniseur de systèmes de fichiers

# Check if a program is installed
# usage : isInstalled program
#		program		Name of the program to test
function isInstalled() {
	which "$1" >> /dev/null
	if [ $? -eq 1 ]; then
		echo "[-] '$1' cannot be found on the system, but it is required" >&2
		exit -1
	fi
}

# Get the absolute path of a file/directory
# usage : getAbsPath file
#		file		File to get the path
function getAbsPath() {	
	readlink -qe "$1"
}

# Scan a directory and list the fileID of the files it contains
# usage : scanDir dir
#		dir		Directory to scan
function scanDir() {
	[ -d "$1" ] || return

	cd "$1"
	# 'find' is fine here, to be recursive and to handle hidden files
	for i in `find . | tail -n+2`; do
		t="d"; [ -d "$i" ] || t="f"
		if $FOLLOW; then
			echo $t,`stat --dereference --printf="%a,%Y,%s,%n" "$i"`
		else
			echo $t,`stat --printf="%a,%Y,%s,%n" "$i"`
		fi
	done
	cd ..
}

# Extract the type from the fileID
# usage : getType fileID
#		fileID		The fileID to work on
function getType() {
	[ $# -eq 1 ] && echo $1 | cut -d',' -f1
}

# Extract the rights from the fileID
# usage : getRigh fileID
#		fileID		The fileID to work on
function getRigh() {
	[ $# -eq 1 ] && echo $1 | cut -d',' -f2
}

# Extract the modification time from the fileID
# usage : getTime fileID
#		fileID		The fileID to work on
function getTime() {
	[ $# -eq 1 ] && echo $1 | cut -d',' -f3
}

# Extract the size from the fileID
# usage : getSize fileID
#		fileID		The fileID to work on
function geSize() {
	[ $# -eq 1 ] && echo $1 | cut -d',' -f3
}

# Extract the name from the fileID
# usage : getName fileID
#		fileID		The fileID to work on
function getName() {
	[ $# -eq 1 ] && echo $1 |  grep -o "\./.\+$"
}

# Find the fileID of a file in a log file
# usage : findInFile fileName logFile
# 		fileName	name of the file to look for, ie './foo.bar'
#		logFile		path to the logFile to look in
function findInFile() {
	[ $# -eq 2 ] && grep ",`getName $1`\$" "$2"
}

# Copy the meta informations of a file to another
# usage : copyMeta fileSrcID fileDstPath
#		fileSrcID	fileID of the source file
#		fileDstPath	Path of the destination file
function copyMeta() {
	[ $# -eq 2 ] || return

	chmod "`getRigh $1`" "$2"
	touch --date="@`getTime $1`" "$2" # We need @ since weR using timestamps
}

# Create an image of a file/directory
# usage : createImage srcDIR dstDIR fileID
#		dirSRC		Path to the directory where the file/directory is located
#		dirDST		Directoty where to create the file image
#		fileID		fileID of the file/directory to make an image of
function createImage() {
	[ $# -eq 3 ] || return

	src="$1/`getName $3`"
	dst="$2/`getName $3`"

	if [ -r "$src" ]; then
		if [ -d "$src" ]; then
			mkdir "$dst"
			copyMeta "$3" "$dst"
		else
			if $FOLLOW; then
				cp --dereference --preserve=mode,timestamps "$src" "$dst"
			else
				cp --no-dereference --preserve=mode,timestamps "$src" "$dst"
			fi
		fi
	else
		$QUIET || echo "[-] Couldnt sync '`getName $3`' : no such file or directory" >&2
	fi
}

function isExcluded() {
	[ $# -eq 1 ] || return
	
	exec 4< "$EXCLUDE"
	while read <&4 f; do
		echo "$1/" | grep "$f"
	done
}

# Try to sync two directory. Rmq : it's a one-side synchronisation
# usage : syncDir srcDir dstDir
#	srcDir		The source directory to synchronise
#	dstDir		The destination directory to be synchronised
function syncDir() {
	[ $# -eq 2 ] || return

	scanDir "$1" > "$TMP_SRC"
	scanDir "$2" > "$TMP_DST"

	echo > $NEW_LOG
	
	$VERBOSE && echo "[+] ==> Scanning $1"

	# We use a file descriptor to be able to use 'read' inside of the loop
	exec 3< "$TMP_SRC"
	while read <&3 srcF; do
		nameF=`getName $srcF`
		dstF=`findInFile "$srcF" "$TMP_DST"`
		orgF=""
		$INIT		|| orgF=`findInFile "$srcF" "$LOGFILE"`
		$VERBOSE	&& echo -e "[+] ($srcF) ($dstF) ($orgF)"
		
		if [ "`isExcluded $nameF`" ]; then
			$QUIET		|| echo -e "[+] '$nameF' has been excluded : skipping"
			$VERBOSE	&& echo
			echo $1/$nameF >> $CONFLIC
			continue
		fi

		# p/B doesnt exist
		if [ "x$dstF" = "x" ]; then
			$VERBOSE && echo -ne "[=] '$nameF' exists in SRC but not in DST : "
			# p/A is not in the log : p/A was created
			if [ "x$orgF" = "x" ]; then
				$VERBOSE && echo -e "[NEW]"
				createImage "$1" "$2" "$srcF"
				echo $srcF >> $NEW_LOG
			# p/A is in the log : p/B was deleted
			else
				$VERBOSE && echo -e "[DEL]"
				$QUIET || echo -en "[+] Delete it? [y/N] "
				
				rep=$FORCE_D_C;
				$QUIET || if $FORCE_D; then
					echo $FORCE_D_C
				else
					read -e rep
				fi

				if [[ "$rep" = [YyOo] ]]; then
					rm -fr "$1/$nameF"
				else
					echo $srcF >> $TMP_ALL		# we gotta keep it here, so it will never be parsed as "NEW"
					echo $1/$nameF >> $CONFLIC
				fi
			fi
		# p/A and p/B exist
		else
			$VERBOSE && echo -e "[=] '$nameF' exists in both directory : [SYNC?]"
			# on of p/A or p/B is a directory, but the other is not
			if [ "`getType "$srcF"`" != "`getType "$dstF"`" ]; then
				$QUIET || echo -e "[-] ($1/$nameF) Types differ ! [CONFLICT=T] + Excluded"
				echo $1/$nameF	>> $CONFLIC
				echo $nameF/	>> $EXCLUDE	# We exclude this one to prevent parsing a file
								# inside of a directory coz it will never be synced

			# p/A & p/B are both directories
			elif [ "`getType "$srcF"`" = "d" ]; then
				$VERBOSE && echo -e "[+] Directory : skipping"
				echo $srcF >> $NEW_LOG

			# p/A & p/B are both regular files
			# p/A matches p/B : *assuming* files are the same
			elif [ "x$srcF" = "x$dstF" ]; then
				$VERBOSE && echo -e "[=] File are the same, checking logFile : [SYNC?]"
				# p/A and p/B match the log : they are synced
				if [ "x$srcF" = "x$orgF" ]; then
					$VERBOSE && echo -e "[+] Files are synced : [SYNC]"
					echo $srcF >> $NEW_LOG
				# p/A and p/B are the same, but dont match the log
				else
					# the logFile was empty/corrupted?
					if [ $INIT ]; then
						$VERBOSE && echo -e "[+] Marked as sync : [SYNC]"
						echo $srcF >> $NEW_LOG
					else
						$QUIET || echo -e "[-] Cannot sync '$nameF', something weird happened ! [CONFLICT=L]"
						$QUIET || echo -ne "[+] Maybe the logfile is corrupted. Fix? [y/N] "
						rep=$FORCE_L_C;
						$QUIET || if $FORCE_L; then
							echo $FORCE_L_C
						else
							read -e rep
						fi

						if [[ "$rep" = [YyOo] ]]; then
							$VERBOSE && echo -e "[+] Logfile fixed !"
							echo $srcF >> $NEW_LOG
						else
							echo $1/$nameF >> $CONFLIC
						fi
					fi
				fi

			# p/A & p/B are both regular files
			# p/A doesnt match p/B
			else
				# p/A matches the log : p/B was modified
				if [ "x$orgF" = "x$srcF" ]; then
					$VERBOSE && echo -e "[+] Syncing '$nameF' : [D]`basename $2` > [S]`basename $1` : [SYNC]"
					createImage "$2" "$1" "$dstF"
					echo $dstF >> $NEW_LOG
				# p/B matches the log : p/A was modified
				elif [ "x$orgF" = "x$dstF" ]; then
					$VERBOSE && echo -e "[+] Syncing '$nameF' : [S]`basename $1` > [D]`basename $2` : [SYNC]"
					createImage "$1" "$2" "$srcF"
					echo $srcF >> $NEW_LOG
				# neither of p/A and p/B match the log
				# do they have the same content?
				elif [ ! "`diff "$1/$nameF" "$2/$nameF"`" ]; then
					rep=$FORCE_M_C;
					$QUIET || if ! $FORCE_M; then
						echo -e "[-] Files have the same content, but weird metas (logFile corrupted?)"
						echo -e "[=] Which metas should I replicate?"
						select i in "$srcF" "$dstF" "None"; do
							rep=$REPLY
							break;
						done
					fi

					if [ "$rep" -eq 1 ]; then
						$VERBOSE && echo -e "[+] Syncing (meta) '$nameF' : [S]`basename $1` > [D]`basename $2` : [SYNC]"
						copyMeta "$srcF" "$2/$nameF"
						echo $srcF >> $NEW_LOG
					elif [ "$rep" -eq 2 ]; then
						$VERBOSE && echo -e "[+] Syncing (meta) '$nameF' : [D]`basename $2` > [S]`basename $1` : [SYNC]"
						copyMeta "$dstF" "$1/$nameF"
						echo $dstF >> $NEW_LOG
					else
						$VERBOSE && echo -e "[+] Unsolved conflit recorded"
						echo $1/$nameF >> $CONFLIC
					fi
				# neither of p/A and p/B match the log
				# they dont have the same content
				else
					if ! $QUIET; then
						echo -e "[-] Cannot sync, contents differ ! [CONFLICT=C]"
						$FORCE_C || echo -ne "SRC $srcF\nDST $dstF\n[+] See the 'diff'? [y/N] "
						$FORCE_C || read -e rep
						$FORCE_C || if [[ "$rep" = [YyOo] ]]; then
							echo
							diff -y "$1/`getName $srcF`" "$2/`getName $dstF`" | less
							echo 
						fi
					fi

					rep=$FORCE_C_C;
					$QUIET || if ! $FORCE_C; then
						echo -e "[=] Which one should I keep?"
						select i in "Source" "Destination" "Dont touch"; do
							rep=$REPLY
							break;
						done
					fi
				
					if [ "$rep" -eq 1 ]; then
						$VERBOSE && echo -e "[+] Syncing '$nameF' : [S]`basename $1` > [D]`basename $2` : [SYNC]"
						createImage "$1" "$2" "$dstF" 
						echo $srcF >> $NEW_LOG
					elif [ "$rep" -eq 2 ]; then
						$VERBOSE && echo -e "[+] Syncing '$nameF' : [D]`basename $2` > [S]`basename $1` : [SYNC]"
						createImage "$2" "$1" "$srcF"
						echo $dstF >> $NEW_LOG
					else
						$VERBOSE && echo -e "[+] Unsolved conflit recorded"
						echo $1/$nameF >> $CONFLIC
					fi
				fi
			fi
		fi

		$VERBOSE && echo
	done
}

# Show the usage of this script
# usage : usage
function usage() {
echo "UTT-rsync   version 0.2 (C) 2012"
	echo -e "Author\tKAAM Gabriel <gabriel.kaam@utt.fr>"
	echo
	echo "UTT-rsync is a file-synchronisation tool"
	echo "It tries to sync two directories, so both of them"
	echo "have exactly the same content"
	echo
	echo "Usage : `basename $0` [OPTION]... SRC DST"
	echo
	echo "Where SRC is the source directory, and DST the destination one"
	echo
	echo "Options can be"
	echo -e " -h,\t--help\t\t\tdisplay this help message"
	echo -e " -o,\t--output=FILE\t\tlog all messages to FILE"
	echo -e "\t\t\t\tDefault : standard output"
	echo -e " -x,\t--exclude=PATTERN\texclude files or directories matching the PATTERN"
	echo -e " -c,\t--content=CHOICE\twhich file to keep when a content conflict happens"
	echo -e "\t\t\t\tCHOICE be can 'source', 'destination' or 'both'"
	echo -e "\t\t\t\tDefault : will ask"
	echo -e " -cS\t\t\t\tlike --content=source"
	echo -e " -cD\t\t\t\tlike --content=destination"
	echo -e " -cB\t\t\t\tlike --content=both"
	echo -e " -l,\t--logfile=PATH\t\tpath to your logfile [default:~/.syncro]"
	echo -e " -p,\t--pidfile=PATH\t\twrite the daemon PID into this file [default:~/.syncro_pid]"
	echo -e " -m,\t--meta=CHOICE\t\twhich file to keep when a meta conflict happens"
	echo -e "\t\t\t\tCHOICE be can 'source', 'destination' or 'both'"
	echo -e "\t\t\t\tDefault : will ask"
	echo -e " -mS\t\t\t\tlike --meta=source"
	echo -e " -mD\t\t\t\tlike --meta=destination"
	echo -e " -mB\t\t\t\tlike --meta=both"
	echo -e " -d,\t--delete=[yes,no]\twhether to replicate a deletion when one happens /!\ Be careful /!\\"
	echo -e "\t\t\t\tDefault : will ask"
	echo -e " -dY\t\t\t\tlike --delete=yes"
	echo -e " -dN\t\t\t\tlike --delete=no"
	echo -e " -f,\t--fix=[yes,no]\t\twhether to correct the logfile when it is corrupted"
	echo -e "\t\t\t\tDefault : will ask"
	echo -e " -fY\t\t\t\tlike --fix=yes"
	echo -e " -fN\t\t\t\tlike --fix=no"
	echo -e " -b,\t--background\t\trun in the background"
	echo -e " -i,\t--initial\t\tignore the logfile (start the synchronisation from scratch)"
	echo -e " -r,\t--dereference\t\talways follow symbolic links"
	echo -e " -q,\t--quiet\t\t\tsuppress non-error messages"
	echo -e " -v,\t--verbose\t\tincrease verbosity"
	exit -1
}

# Clean temp files
# usage : clean
function clean() {
	rm -f "$TMP_ALL" "$TMP_SRC" "$TMP_DST" "$CONFLIC" "$EXCLUDE" "$NEW_LOG_1" "$NEW_LOG_2"
}

trap clean EXIT

[ $# -ge 2 ] || usage

isInstalled diff
isInstalled stat
isInstalled readlink

FORCE_D=false		# false => will ask if a file deletion happens
			# true => will act according to FORCE_D_C
FORCE_D_C="n"		# "n" => will never delete
			# "y" => will always delete
FORCE_L=false		# false => will ask if the logfile is corrupted
			# true => will act according to FORCE_L_C
FORCE_L_C="n"		# "n" => logfile will not be fixed
			# "y" => it will be
FORCE_C=false		# false => will ask if a conflict on content happens
			# true => allow conflicting files to be automaticely synced
FORCE_C_C=3		# 1 => the source file will remain
			# 2 => the destination file will remain
			# 3 => nothing is done
FORCE_M=false		# false => will ask if a conflict of meta happens
			# true => allow meta to automaticely synced
FORCE_M_C=3		# 1 => the source file's metas will remain
			# 2 => the destination file's metas will remain
			# 3 => nothing is done
LOGFILE="$HOME/.synchro"
PIDFILE="$HOME/.synchro_pid"
OUTFILE=""
ISDAEMON=false
DAEMON=false
VERBOSE=false
QUIET=false
INIT=false
FOLLOW=false
keep="$@"		# used to daemonize

t=$RANDOM
TMP_SRC="/tmp/tree_SRC_$$"_$t
TMP_DST="/tmp/tree_DST_$$"_$t
TMP_ALL="/tmp/tree_ALL_$$"_$t
CONFLIC="/tmp/tree_CON_$$"_$t
EXCLUDE="/tmp/tree_EXC_$$"_$t
NEW_LOG_1="/tmp/tree_LOG_1_$$_"$r
NEW_LOG_2="/tmp/tree_LOG_2_$$_"$r

while [ $# -gt 2 ]; do
	o="`echo $1 | tr '[:upper:]' '[:lower:]'`"
	p="`echo $2 | tr '[:upper:]' '[:lower:]'`"
	c1="`echo $1 | cut -d'=' -f1`"
	c2="`echo $1 | cut -d'=' -f2`"
	case "$o" in
		-h|--help)
			usage
			;;
		-b|--background)
			DAEMON=true
			;;
		-id)
			ISDAEMON=true
			;;
		-v|--verbose)
			VERBOSE=true
			;;
		-q|--quiet)
			QUIET=true
			;;
		-r|--dereference)
			FOLLOW=true
			;;
		-i|--initial)
			INIT=true
			;;
		-d|--delete)
			[ "$o" = "y" ] && o=yes
			[ "$o" = "n" ] && o=no
			# We modify $2 to parse it correctly on next loop
			set -- "${@:1:1}" "--delete=$p" "${@:3}"
			;;
		-dy|-dyes|--delete=yes|--delete=y)
			FORCE_D=true
			FORCE_D_C="y"
			;;
		-dn|-dno|--delete=no|--delete=n)
			FORCE_D=true
			FORCE_D_C="n"
			;;
		-f|--fix)
			[ "$o" = "y" ] && o=yes
			[ "$o" = "n" ] && o=no
			set -- "${@:1:1}" "--fix=$p" "${@:3}"
			;;
		-fy|-fyes|--fix=yes|--fix=y)
			FORCE_L=true
			FORCE_L_C="y"
			;;
		-fn|-fno|--fix=no|--fix=n)
			FORCE_L=true
			FORCE_L_C="n"
			;;
		-c|--content)
			[ "$o" = "s" ] && o=source
			[ "$o" = "d" ] && o=destination
			[ "$o" = "b" ] && o=both
			set -- "${@:1:1}" "--content=$p" "${@:3}"
			;;
		-cs|-csource|--content=source)
			FORCE_C=true
			FORCE_C_C=1
			;;
		-cd|-cdestination|--content=destination)
			FORCE_C=true
			FORCE_C_C=2
			;;
		-cb|-cboth|--content=both)
			FORCE_C=true
			FORCE_C_C=3
			;;
		-m|--meta)
			[ "$o" = "s" ] && o=source
			[ "$o" = "d" ] && o=destination
			[ "$o" = "b" ] && o=both
			set -- "${@:1:1}" "--meta=$p" "${@:3}"
			;;
		-ms|-msource|--meta=source)
			FORCE_M=true
			FORCE_M_C=1
			;;
		-md|-mdestination|--meta=destination)
			FORCE_M=true
			FORCE_M_C=2
			;;
		-mb|-mboth|--meta=both)
			FORCE_M=true
			FORCE_M_C=3
			;;
		*)
			case "$c1" in
				-l|--logfile)
					if [ "x$c1" = "x-l" ]; then
						LOGFILE="$2"
						shift
					elif [ "$(echo $1 | grep '=')" ]; then
						LOGFILE="$c2"
					else
						LOGFILE="$2"
						shift
					fi
					;;
				-p|--pidfile)
					if [ "x$c1" = "x-p" ]; then
						PIDFILE="$2"
						shift
					elif [ "$(echo $1 | grep '=')" ]; then
						PIDFILE="$c2"
					else
						PIDFILE="$2"
						shift
					fi
					;;
				-o|--output)
					if [ "x$c1" = "x-o" ]; then
						OUTFILE="$2"
						shift
					elif [ "$(echo $1 | grep '=')" ]; then
						OUTFILE="$c2"
					else
						OUTFILE="$2"
						shift
					fi
					;;
				-x|--exclude)
					if [ "x$c1" = "x-x" ]; then
						echo $2 >> $EXCLUDE
						shift
					elif [ "$(echo $1 | grep '=')" ]; then
						echo $c2 >> $EXCLUDE
					else
						echo $2 >> $EXCLUDE
						shift
					fi
					;;
				*)
					echo "[-] Unrecognized argument : $1"
					exit -1
					;;
			esac
	esac
	shift
done

if $DAEMON; then
	if ! $ISDAEMON; then
		$0 -id $keep &
		echo $! > "$PIDFILE"
		exit 0
	else
		FORCE_D=true;
		FORCE_M=true;
		FORCE_C=true;
		FORCE_L=true;
	fi
fi

SRC="$1"
DST="$2"

touch "$EXCLUDE"
touch "$CONFLIC"
touch "$TMP_ALL"
$QUIET	&& VERBOSE=false
$INIT	&& touch "$LOGFILE"
[ "x$OUTFILE" = "x" ] || exec 1> "$OUTFILE"

if [ ! -f "$LOGFILE" ] || [ ! -w "$LOGFILE" ]; then
	echo "[-] Invalid logfile ..." >&2
	exit -1
fi
if [ ! -d "$SRC" ] || [ ! -d "$DST" ]; then
	echo "[-] No such directory" >&2
	exit -1
fi

SRC=`getAbsPath "$SRC"`
DST=`getAbsPath "$DST"`

# If the logfile is empty, we assume it's the first run
[ "`stat --printf=%s "$LOGFILE"`" = "0" ] && INIT=true

NEW_LOG=$NEW_LOG_1 syncDir "$SRC" "$DST"
FORCE_C=true;	FORCE_C_C=3;	# this is useful if a conflict(C/M) has been ignored during first syncDir
FORCE_M=true;	FORCE_M_C=3;	# we dont want to ask a second time for a resolution
NEW_LOG=$NEW_LOG_2 syncDir "$DST" "$SRC"

cat "$TMP_ALL" "$NEW_LOG_2" | sed '/^$/d' > $LOGFILE
[ "`stat --printf=%s "$LOGFILE"`" = "0" ] || $QUIET || echo -e "[+] Files successfully synchronized\n`sort $LOGFILE`"
if [ ! "`stat --printf=%s "$CONFLIC"`" = "0" ]; then
	$QUIET || echo -e "[+] Some files werent synchronized\n`sort $CONFLIC`"
	exit 1
fi

exit 0
