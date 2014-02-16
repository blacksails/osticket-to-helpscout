# osTicket import tool for Help Scout

I wrote this tool when the company i work for decided to exchange osTicket with Help Scout. In order to use the tool you need a database connection to the osTicket database, and a folder containing the attachments. Before the tool is launched, we create the users which appear in osTicket in HelpScout.

There is a limit on requests on the Help Scout API, therefore it maybe nessesary to change the API key a few times. To continue the import simply delete the lastly imported ticket in Help Scout, and find the osTicket ticket\_id for the ticket before this one. Then change the WHERE clause in the get\_tickets method so that ticket_id > "the second last imported ticket".
