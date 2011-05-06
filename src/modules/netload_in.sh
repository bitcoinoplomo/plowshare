#!/bin/bash
#
# netload.in module
# Copyright (c) 2010-2011 Plowshare team
#
# This file is part of Plowshare.
#
# Plowshare is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Plowshare is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Plowshare.  If not, see <http://www.gnu.org/licenses/>.

MODULE_NETLOAD_IN_REGEXP_URL="http://\(www\.\)\?net\(load\|folder\)\.in/"
MODULE_NETLOAD_IN_DOWNLOAD_OPTIONS=""
MODULE_NETLOAD_IN_DOWNLOAD_CONTINUE=no
MODULE_NETLOAD_IN_LIST_OPTIONS=""

# Output an netload.in file download URL (anonymous, NOT PREMIUM)
#
# netload_in_download NETLOAD_IN_URL
#
netload_in_download() {
    set -e
    eval "$(process_options netload_in "$MODULE_NETLOAD_IN_DOWNLOAD_OPTIONS" "$@")"

    URL=$(echo "$1" | replace 'www.' '')
    BASE_URL="http://netload.in"
    COOKIES=$(create_tempfile)

    local TRY=0
    while retry_limit_not_reached || return 3; do
        ((TRY++))
        WAIT_URL=$(curl --location -c $COOKIES "$URL" | \
            parse_quiet '<div class="Free_dl">' '><a href="\([^"]*\)') ||
            { log_debug "file not found"; return 254; }

        if test "$CHECK_LINK"; then
            rm -f $COOKIES
            return 255
        fi

        PERL_PRG=$(detect_perl) || { rm -f $COOKIES; return 1; }

        WAIT_URL="$BASE_URL/${WAIT_URL//&amp;/&}"
        WAIT_HTML=$(curl -b $COOKIES -e $URL --location $WAIT_URL)
        WAIT_TIME=$(echo "$WAIT_HTML" | parse_quiet 'type="text\/javascript">countdown' \
                "countdown(\([[:digit:]]*\),'change()')")

        if test -n "$WAIT_TIME"; then
            wait $((WAIT_TIME / 100)) seconds || return 2
        fi

        CAPTCHA_URL=$(echo "$WAIT_HTML" | parse '<img style="vertical-align' \
                'src="\([^"]*\)" alt="Sicherheitsbild"')
        CAPTCHA_URL="$BASE_URL/$CAPTCHA_URL"

        log_debug "Try $TRY:"

        CAPTCHA=$(curl -b $COOKIES "$CAPTCHA_URL" | $PERL_PRG $LIBDIR/strip_single_color.pl |
                convert - -quantize gray -colors 32 -blur 40% -contrast-stretch 6% -compress none -depth 8 tif:- |
                show_image_and_tee | ocr digit | sed "s/[^0-9]//g") ||
                { log_error "error running OCR"; return 1; }

        test "${#CAPTCHA}" -gt 4 && CAPTCHA="${CAPTCHA:0:4}"
        log_debug "Decoded captcha: $CAPTCHA"

        if [ "${#CAPTCHA}" -ne 4 ]; then
            log_debug "Captcha length invalid"
            continue
        fi

        # Send (post) form
        local download_form=$(grep_form_by_order "$WAIT_HTML" 1)
        local form_url=$(echo "$download_form" | parse_form_action)
        local form_fid=$(echo "$download_form" | parse_form_input_by_name 'file_id')

        WAIT_HTML2=$(curl -l -b $COOKIES --data "file_id=${form_fid}&captcha_check=${CAPTCHA}&start=" \
                "$BASE_URL/$form_url")

        match 'class="InPage_Error"' "$WAIT_HTML2" &&
            { log_debug "Error (bad captcha), retry"; continue; }

        log_debug "Correct captcha!"

        WAIT_TIME2=$(echo "$WAIT_HTML2" | parse_quiet 'type="text\/javascript">countdown' \
                "countdown(\([[:digit:]]*\),'change()')")

        if [ -n "$WAIT_TIME2" ]
        then
            if [[ "$WAIT_TIME2" -gt 10000 ]]
            then
                log_debug "Download limit reached!"
                wait $((WAIT_TIME2 / 100)) seconds || return 2
            else
                # Supress this wait will lead to a 400 http error (bad request)
                wait $((WAIT_TIME2 / 100)) seconds || return 2
                break
            fi
        fi

    done

    rm -f $COOKIES

    FILENAME=$(echo "$WAIT_HTML2" |\
        parse_quiet '<h2>[Dd]ownload:' '<h2>[Dd]ownload:[[:space:]]*\([^<]*\)')
    FILE_URL=$(echo "$WAIT_HTML2" |\
        parse '<a class="Orange_Link"' 'Link" href="\(http[^"]*\)')

    echo $FILE_URL
    test -n "$FILENAME" && echo "$FILENAME"
    return 0
}

# List multiple netload.in links
# $1: netfolder.in link
# stdout: list of links
netload_in_list() {
    eval "$(process_options netload_in "$MODULE_NETLOAD_IN_LIST_OPTIONS" "$@")"
    URL=$1

    if ! match 'folder' "$URL"; then
        log_error "This is not a directory list"
        return 1
    fi

    LINKS=$(curl "$URL" | break_html_lines_alt | parse_all_attr 'Link_[[:digit:]]' 'href') || \
        { log_error "Wrong directory list link"; return 1; }

    if test -z "$LINKS"; then
        log_error "This is not a directory list"
        return 1
    fi

    echo "$LINKS"
    return 0
}
