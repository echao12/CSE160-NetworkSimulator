interface CommandHandler{
   // Events
   event void ping(uint16_t destination, uint8_t *payload);
   event void pingReply(uint16_t destination);
   event void broadcast(uint16_t destination, uint8_t *payload);
   event void flood(uint16_t destination, uint8_t *payload);
   event void printNeighbors();
   event void printRouteTable();
   event void printLinkState();
   event void printDistanceVector();
   event void setTestServer(uint16_t port);
   event void setTestClient(uint16_t destination, uint16_t sourcePort, uint16_t destinationPort, uint16_t transfer);
   event void setAppServer();
   event void setAppClient();
   event void closeClient( uint16_t destination, uint16_t srcPort, uint16_t destPort);
}
