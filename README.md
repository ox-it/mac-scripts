# OS X related scripts 

Published by the Mac team at the [University of Oxford](http://www.ox.ac.uk) [IT Services](http://www.it.ox.ac.uk).

The majority of the published content have been build with wider adoption in mind. However, as Oxford uses the [Casper Suite](http://www.jamfsoftware.com) it might require more work to adopt this to other management frameworks.

## TOC

##### Java Browser Plugin (java7-browser-plugin)  
Scripts to manage (read disable) the Java 7 browser plug-in and check its status:

 * *Java_7_Post_Install.sh*: this post-installation script for the Oracle Java 7 installer disables by default the browser plug-in after each installation or update. It is also respects the status of the *Java Web Plugin Master Switch*. The script also creates a persistent convenience link for the Java version one might use to configure environment variables or use in scripts <tt>/Library/Java/JavaVirtualMachines/${VERSION}</tt>.
 * *Java_7_Plugin_Version_and_Status-ExtAttr.sh*:
 * *Web_Java_Master_Switch.sh*: self-service script to enable the end-user to control the status of the Java 7 browser plugin. This script could be made available in self service to all users or subgroups based on sophisticated scoping mechanisms. Please note that  script requires [cocaDialog](http://mstratman.github.io/cocoadialog/).


##### Tivoli Storage Manager (tivoli-storage-manager)  
Scripts to collect status information on a Tivoli Storage Manager client and backup status.
