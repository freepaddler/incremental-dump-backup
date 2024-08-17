#!/bin/sh
#set -x

tmp_file="tmp_restore"
ssh_opt="-qS ./rd-$(date '+%m%d%H%M%Y.%S') "

usage(){
    cat << EOF

This sript generates restore file "restore_xxxx.sh" ans runs it to 
restore filesystem dump.
If restoring to the live system, it is better to restore root filesystem 
the last one. 
It may be run from directly connected drive for restore purpose
or copied to remote machine and run to restore remote backup.
If booting from live CD - please read "Memory disk" section below.

Options:
    -a list all available dates to restore
    -l generate file for the lates date available
    -d set restore date in YYYYMMDD format
    -f path FROM where to get dump files
    -t path TO where to extract dump (should be mounted)
    -s ssh connection string for remote restore like user@host.local

Usage:
    restore_inc.sh -a -f /backup/hostname/dir/ [-s user@host.local]
    restore_inc.sh -l -t /mnt/vardir -f /backup/hostname/dir/ [-s user@host.local]
    restore_inc.sh -d YYYYMMDD -t /mnt/vardir -f /backup/hostname/dir/ [-s user@host.local]

Memory disk:
    If restoring from live media create memory drive and give 
    it as much memory as possible, or mount writable volume for $TMPDIR

mdconfig -a -s 1g -u md0
newfs -U md0
mount /dev/md0 /mnt/
mkdir /mnt/tmp
export TMPDIR="/mnt/tmp"

EOF
exit 1
}

# check_mount_point mount_point
#   check if mount point exists and mounted
#
check_mount_point(){
    for _mp in $(mount -p -t ufs | awk '{print $2}'); do
        [ "$1" = "$_mp" ] && return 0
    done
    return 1
}

# check_ssh 
#   check if ssh connection may be established
#   setup multiplex ssh connection
#
check_ssh(){
    [ ! -z "$ssh_string" ] && \
        if ssh -M -o "ControlPersist 120s" $ssh_opt $ssh_string exit 0; then 
            ssh_cmd="ssh $ssh_opt $ssh_string" 
            return 0
        else
            echo "Unable to establish ssh session $ssh_string!" 
            return 1
        fi
    ssh_cmd=""
    return 0
}

# check_bkp_path path
#   check id backup path exists
#
check_bkp_path(){
    if $ssh_cmd [ ! -d "$1" ]; then
    	echo "Unable to access backups directory!"
    	return 1
    fi
    return 0
}

# list_dates
#   list all available dates to restore
#
list_dates(){
    $ssh_cmd ls -t1 $from/*.dump.gz | awk '{FS="/"; n=split($NF,a,"."); print a[1]}' | tail -r
    exit 0
}

# gen_restore restore_date
#   generate restore file with correct order 
#   of dump and mtree files
gen_restore(){
    file="restore_$(basename $from).sh"
    gzip_cmd="gzip -cd $from"
    restore_cmd="| (cd $to && restore -ruf -)"
    $ssh_cmd ls -t1 $from/*dump.gz | awk '{FS="/"; print $NF }' | while IFS="." read -r date type lvl ending; do
        if ([ -z $cur_lvl ] && [ "$1" = "$date" ]) || ([ ! -z $cur_lvl ] && [ $lvl -lt $cur_lvl ]); then
            cat <<EOF >> $tmp_file
[ \$? -eq 0 ] || { echo "ERROR! Restore failed!"; exit 1; }
$ssh_cmd $gzip_cmd/$date.$type.$lvl.$ending $restore_cmd
echo "Restoring $date.$type.$lvl.$ending..."
echo
EOF
            cur_lvl=$lvl
        fi
        if [ ! -z $cur_lvl ] && [ $cur_lvl = "1" ]; then
            break;
        fi
    done;
    cat <<EOF >> $tmp_file
[ \$? -eq 0 ] || { echo "ERROR! Restore failed!"; exit 1; }
$ssh_cmd $gzip_cmd/0.base.dump.gz $restore_cmd
echo Restoring 0.base.dump.gz...
echo
#!/bin/sh
EOF
    tail -r $tmp_file > $file
    cat <<EOF >> $file
echo
echo -n "deleting: "
rm -rfv $to/restoresymtable
EOF
    rm -rf $tmp_file
    chmod +x $file
    echo Restore File is ready: $(pwd)/$file
}

# script body
#   read options, run necessary backup rutine
#
while getopts "f:t:d:s:la" OPT; do
    case $OPT in
        f) from="$OPTARG" ;;
        t) to="$OPTARG" ;;
        l) last=1 ;;
        d) restore_date="$OPTARG" ;;
        a) run_list_dates=1 ;;
        s) ssh_string="$OPTARG" ;;
        \?) usage ;;
    esac
done
[ $OPTIND -ne 1 ] || usage

if [ ! -z $restore_date ] && [ ! -z $last ]; then
    echo "Do not use -l and -d options and the same time!"
    usage
fi

check_ssh || exit 1
check_bkp_path $from || exit 1

[ ! -z $run_list_dates ] && list_dates

check_mount_point $to || { echo "Wrong restore destination!"; exit 1; }

[ ! -z $last ] && restore_date=$($ssh_cmd ls -t1 $from/*.dump.gz | head -1 | awk '{FS="/"; n=split($NF,a,"."); print a[1]}')
    
if echo $restore_date | egrep '^[0-9]{4}[01][0-9][0-3][0-9]([~]?[0-9]+)?$'; then
    gen_restore "$restore_date"
    echo "Resulted file:"
    cat $file | grep "restore"
    read -p "Proceed with restore (yes/no): " -r ANSW
    echo
    if [ "$ANSW" = "yes" ]; then 
	    ./$file
	else 
	    echo "Run $(pwd)/$file to start restore..."
    fi;
else 
    echo "Wrong restore date!"
    usage
fi

exit 0
