<!DOCTYPE html>
<body>
<p>Greetings Team wolfSSL,</p></br></br>
<p>Project "${project.name}" has reported a ${build.result} status. Details follow:</p></br>
<p>Build URL: ${rooturl}${build.url} </p>
<p>Date of build: ${it.timestampString} </p>
<p>Build duration: ${build.durationString} </p>

<p>

    <TABLE width="100%">
        <TR>
            <TD class="bg1" colspan="2">ERRORS</TD>
        </TR>
<%
    def publisher = null

    def extractInts( String input ) {
        input.findAll( /\d+/ )*.toInteger()
    }


    for (iter in project.getPublishersList()) {
        if (iter.getDescriptor().getDisplayName().equals("Editable Email Notification")) {
            publisher = iter
            break
        }
    }
    if (publisher != null) {
        def logParserResult
        //Get the LogParserAction from Jenkins
        for (action in build.getActions()) {
            if (action.toString().contains("LogParserAction")) {
                //Get the LogParserResult from the LogParserAction
                logParserResult = action.getResult()
                break
            }
        }

        //Get the ErrorLinksFile from the LogParserResult
        def errorLinksFile   = new File (logParserResult.getErrorLinksFile())
        def infoLinksFile    = new File (logParserResult.getInfoLinksFile())
        def warningLinksFile = new File (logParserResult.getWarningLinksFile())

        //Rewrite the URL so it directs to something useful
        pattern = ~/<a.*?><font.*?>/
        def errorList = []
        def warningList = []
        def parsedFile = []
        count_config_options = 0
        check_for_errors = 0
        check_for_warnings = 0

        for (err_line in errorLinksFile.getText().split("\n")) {
            if (err_line.contains("href")) {
                check_for_errors += 1
            }
        }

        for (warn_line in warningLinksFile.getText().split("\n")) {
            if (warn_line.contains("href")) {
                check_for_warnings += 1
            }
        }

        for (err_line in errorLinksFile.getText().split("\n")) {
            parsedFile.add(err_line)
        }

        for (i = 0; i < parsedFile.size() - 1; i++) {
            err_line = parsedFile[i]
            //All errors have a link, so this makes sure no superfluous text is displayed
            if (err_line.contains("HEADER HERE: #") && parsedFile[i+1].contains("HEADER HERE: #")) {
                continue
            }
            else if (err_line.contains("HEADER HERE: #") && !parsedFile[i+1].contains("HEADER HERE: #")) {
                count_config_options += 1
                def parts = err_line.split("#")
                def target_header = parts[1].toInteger()
                //parts[1] should now contain the number for the proper header that belong there.
                for (info_line in infoLinksFile.getText().split("\n")) {
                    def value_to_match = extractInts(info_line)
                    if (value_to_match[0] == target_header) {
                        errorList.add(info_line.replaceAll(pattern, "<a href="+ rooturl + build.url + "parsed_console/?\">").minus("</font>"))
                    }
                }
                continue
            }
            errorList.add(err_line.replaceAll(pattern,
                                                 "<a style=\"color:red;padding-left:40px\"  xhref="+ rooturl + build.url
                                                 + "parsed_console/?\">"
                                                 ).minus("</font>"))
        }
%>
        <TR>
            <TD class="bg2" colspan="2">Total : ${errorList.count{it} - count_config_options} error(s)</TD>
        </TR>
<%
        if (check_for_errors > 0) {
            for(error in errorList){
%>
        <TR>
            <TD class="errors" colspan="2">${error}</TD>
        </TR>
<%
            }
        }

        count_config_options = 0
        parsedFile = []

        for (warn_line in warningLinksFile.getText().split("\n")) {
            parsedFile.add(warn_line)
        }

        for (i = 0; i < parsedFile.size() - 1; i++) {
            warn_line = parsedFile[i]
            //All errors have a link, so this makes sure no superfluous text is displayed
            if (warn_line.contains("HEADER HERE: #") && parsedFile[i+1].contains("HEADER HERE: #")) {
                continue
            }
            else if (warn_line.contains("HEADER HERE: #") && !parsedFile[i+1].contains("HEADER HERE: #")) {
                count_config_options += 1
                def parts = warn_line.split("#")
                def target_header = parts[1].toInteger()
                //parts[1] should now contain the number for the proper header that belong there.
                for (info_line in infoLinksFile.getText().split("\n")) {
                    def value_to_match = extractInts(info_line)
                    if (value_to_match[0] == target_header) {
                        warningList.add(info_line.replaceAll(pattern, "<a href="+ rooturl + build.url + "parsed_console/?\">").minus("</font>"))
                    }
                }
                continue
            }
            warningList.add(warn_line.replaceAll(pattern,
                                                 "<a style=\"color:#d66a00;padding-left:40px\" xhref="+ rooturl + build.url
                                                 + "parsed_console/?\">"
                                                 ).minus("</font>"))
        }
%>
        <TR>
            <TD class="bg2" colspan="2">Total : ${warningList.count{it} - count_config_options} warning(s)</TD>
        </TR>
<%
        if (check_for_warnings > 0) {
            for(warning in warningList){
%>
        <TR>
            <TD colspan="2">${warning}</TD>
        </TR>
<%
            }
        }
    }
%>
    </TABLE>
</p></br></br>
<p>
Best Regards,</br>
</br>
testing@wolfssl.com
</p>
</body>
</html>
