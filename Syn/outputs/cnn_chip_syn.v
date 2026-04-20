module cnn_chip(clk, rst_n, start, ext_act_in, ext_act_valid, done, fc_result,
     fc_valid);
input clk, rst_n, start, ext_act_valid;
output done, fc_valid;
input  [255:0] ext_act_in;
output [31:0] fc_result;
wire [255:0] net_ext_act_in;
wire [31:0] net_fc_result;
wire net_clk, net_rst_n, net_start, net_ext_act_valid, net_done, net_fc_valid;
    PIW PIW_clk (.PAD(clk), .C(net_clk));
    PIW PIW_rst_n (.PAD(rst_n), .C(net_rst_n));
    PIW PIW_start (.PAD(start), .C(net_start));
    PIW PIW_ext_act_valid (.PAD(ext_act_valid), .C(net_ext_act_valid));
    PIW \gen_piw_ext_act_in[0].PIW_ext_act_in_inst  (.PAD(ext_act_in[0]),
        .C(net_ext_act_in[0]));
    PIW \gen_piw_ext_act_in[1].PIW_ext_act_in_inst  (.PAD(ext_act_in[1]),
        .C(net_ext_act_in[1]));
    PIW \gen_piw_ext_act_in[2].PIW_ext_act_in_inst  (.PAD(ext_act_in[2]),
        .C(net_ext_act_in[2]));
    PIW \gen_piw_ext_act_in[3].PIW_ext_act_in_inst  (.PAD(ext_act_in[3]),
        .C(net_ext_act_in[3]));
    PIW \gen_piw_ext_act_in[4].PIW_ext_act_in_inst  (.PAD(ext_act_in[4]),
        .C(net_ext_act_in[4]));
    PIW \gen_piw_ext_act_in[5].PIW_ext_act_in_inst  (.PAD(ext_act_in[5]),
        .C(net_ext_act_in[5]));
    PIW \gen_piw_ext_act_in[6].PIW_ext_act_in_inst  (.PAD(ext_act_in[6]),
        .C(net_ext_act_in[6]));
    PIW \gen_piw_ext_act_in[7].PIW_ext_act_in_inst  (.PAD(ext_act_in[7]),
        .C(net_ext_act_in[7]));
    PIW \gen_piw_ext_act_in[8].PIW_ext_act_in_inst  (.PAD(ext_act_in[8]),
        .C(net_ext_act_in[8]));
    PIW \gen_piw_ext_act_in[9].PIW_ext_act_in_inst  (.PAD(ext_act_in[9]),
        .C(net_ext_act_in[9]));
    PIW \gen_piw_ext_act_in[10].PIW_ext_act_in_inst  (.PAD(ext_act_in[10]),
        .C(net_ext_act_in[10]));
    PIW \gen_piw_ext_act_in[11].PIW_ext_act_in_inst  (.PAD(ext_act_in[11]),
        .C(net_ext_act_in[11]));
    PIW \gen_piw_ext_act_in[12].PIW_ext_act_in_inst  (.PAD(ext_act_in[12]),
        .C(net_ext_act_in[12]));
    PIW \gen_piw_ext_act_in[13].PIW_ext_act_in_inst  (.PAD(ext_act_in[13]),
        .C(net_ext_act_in[13]));
    PIW \gen_piw_ext_act_in[14].PIW_ext_act_in_inst  (.PAD(ext_act_in[14]),
        .C(net_ext_act_in[14]));
    PIW \gen_piw_ext_act_in[15].PIW_ext_act_in_inst  (.PAD(ext_act_in[15]),
        .C(net_ext_act_in[15]));
    PIW \gen_piw_ext_act_in[16].PIW_ext_act_in_inst  (.PAD(ext_act_in[16]),
        .C(net_ext_act_in[16]));
    PIW \gen_piw_ext_act_in[17].PIW_ext_act_in_inst  (.PAD(ext_act_in[17]),
        .C(net_ext_act_in[17]));
    PIW \gen_piw_ext_act_in[18].PIW_ext_act_in_inst  (.PAD(ext_act_in[18]),
        .C(net_ext_act_in[18]));
    PIW \gen_piw_ext_act_in[19].PIW_ext_act_in_inst  (.PAD(ext_act_in[19]),
        .C(net_ext_act_in[19]));
    PIW \gen_piw_ext_act_in[20].PIW_ext_act_in_inst  (.PAD(ext_act_in[20]),
        .C(net_ext_act_in[20]));
    PIW \gen_piw_ext_act_in[21].PIW_ext_act_in_inst  (.PAD(ext_act_in[21]),
        .C(net_ext_act_in[21]));
    PIW \gen_piw_ext_act_in[22].PIW_ext_act_in_inst  (.PAD(ext_act_in[22]),
        .C(net_ext_act_in[22]));
    PIW \gen_piw_ext_act_in[23].PIW_ext_act_in_inst  (.PAD(ext_act_in[23]),
        .C(net_ext_act_in[23]));
    PIW \gen_piw_ext_act_in[24].PIW_ext_act_in_inst  (.PAD(ext_act_in[24]),
        .C(net_ext_act_in[24]));
    PIW \gen_piw_ext_act_in[25].PIW_ext_act_in_inst  (.PAD(ext_act_in[25]),
        .C(net_ext_act_in[25]));
    PIW \gen_piw_ext_act_in[26].PIW_ext_act_in_inst  (.PAD(ext_act_in[26]),
        .C(net_ext_act_in[26]));
    PIW \gen_piw_ext_act_in[27].PIW_ext_act_in_inst  (.PAD(ext_act_in[27]),
        .C(net_ext_act_in[27]));
    PIW \gen_piw_ext_act_in[28].PIW_ext_act_in_inst  (.PAD(ext_act_in[28]),
        .C(net_ext_act_in[28]));
    PIW \gen_piw_ext_act_in[29].PIW_ext_act_in_inst  (.PAD(ext_act_in[29]),
        .C(net_ext_act_in[29]));
    PIW \gen_piw_ext_act_in[30].PIW_ext_act_in_inst  (.PAD(ext_act_in[30]),
        .C(net_ext_act_in[30]));
    PIW \gen_piw_ext_act_in[31].PIW_ext_act_in_inst  (.PAD(ext_act_in[31]),
        .C(net_ext_act_in[31]));
    PIW \gen_piw_ext_act_in[32].PIW_ext_act_in_inst  (.PAD(ext_act_in[32]),
        .C(net_ext_act_in[32]));
    PIW \gen_piw_ext_act_in[33].PIW_ext_act_in_inst  (.PAD(ext_act_in[33]),
        .C(net_ext_act_in[33]));
    PIW \gen_piw_ext_act_in[34].PIW_ext_act_in_inst  (.PAD(ext_act_in[34]),
        .C(net_ext_act_in[34]));
    PIW \gen_piw_ext_act_in[35].PIW_ext_act_in_inst  (.PAD(ext_act_in[35]),
        .C(net_ext_act_in[35]));
    PIW \gen_piw_ext_act_in[36].PIW_ext_act_in_inst  (.PAD(ext_act_in[36]),
        .C(net_ext_act_in[36]));
    PIW \gen_piw_ext_act_in[37].PIW_ext_act_in_inst  (.PAD(ext_act_in[37]),
        .C(net_ext_act_in[37]));
    PIW \gen_piw_ext_act_in[38].PIW_ext_act_in_inst  (.PAD(ext_act_in[38]),
        .C(net_ext_act_in[38]));
    PIW \gen_piw_ext_act_in[39].PIW_ext_act_in_inst  (.PAD(ext_act_in[39]),
        .C(net_ext_act_in[39]));
    PIW \gen_piw_ext_act_in[40].PIW_ext_act_in_inst  (.PAD(ext_act_in[40]),
        .C(net_ext_act_in[40]));
    PIW \gen_piw_ext_act_in[41].PIW_ext_act_in_inst  (.PAD(ext_act_in[41]),
        .C(net_ext_act_in[41]));
    PIW \gen_piw_ext_act_in[42].PIW_ext_act_in_inst  (.PAD(ext_act_in[42]),
        .C(net_ext_act_in[42]));
    PIW \gen_piw_ext_act_in[43].PIW_ext_act_in_inst  (.PAD(ext_act_in[43]),
        .C(net_ext_act_in[43]));
    PIW \gen_piw_ext_act_in[44].PIW_ext_act_in_inst  (.PAD(ext_act_in[44]),
        .C(net_ext_act_in[44]));
    PIW \gen_piw_ext_act_in[45].PIW_ext_act_in_inst  (.PAD(ext_act_in[45]),
        .C(net_ext_act_in[45]));
    PIW \gen_piw_ext_act_in[46].PIW_ext_act_in_inst  (.PAD(ext_act_in[46]),
        .C(net_ext_act_in[46]));
    PIW \gen_piw_ext_act_in[47].PIW_ext_act_in_inst  (.PAD(ext_act_in[47]),
        .C(net_ext_act_in[47]));
    PIW \gen_piw_ext_act_in[48].PIW_ext_act_in_inst  (.PAD(ext_act_in[48]),
        .C(net_ext_act_in[48]));
    PIW \gen_piw_ext_act_in[49].PIW_ext_act_in_inst  (.PAD(ext_act_in[49]),
        .C(net_ext_act_in[49]));
    PIW \gen_piw_ext_act_in[50].PIW_ext_act_in_inst  (.PAD(ext_act_in[50]),
        .C(net_ext_act_in[50]));
    PIW \gen_piw_ext_act_in[51].PIW_ext_act_in_inst  (.PAD(ext_act_in[51]),
        .C(net_ext_act_in[51]));
    PIW \gen_piw_ext_act_in[52].PIW_ext_act_in_inst  (.PAD(ext_act_in[52]),
        .C(net_ext_act_in[52]));
    PIW \gen_piw_ext_act_in[53].PIW_ext_act_in_inst  (.PAD(ext_act_in[53]),
        .C(net_ext_act_in[53]));
    PIW \gen_piw_ext_act_in[54].PIW_ext_act_in_inst  (.PAD(ext_act_in[54]),
        .C(net_ext_act_in[54]));
    PIW \gen_piw_ext_act_in[55].PIW_ext_act_in_inst  (.PAD(ext_act_in[55]),
        .C(net_ext_act_in[55]));
    PIW \gen_piw_ext_act_in[56].PIW_ext_act_in_inst  (.PAD(ext_act_in[56]),
        .C(net_ext_act_in[56]));
    PIW \gen_piw_ext_act_in[57].PIW_ext_act_in_inst  (.PAD(ext_act_in[57]),
        .C(net_ext_act_in[57]));
    PIW \gen_piw_ext_act_in[58].PIW_ext_act_in_inst  (.PAD(ext_act_in[58]),
        .C(net_ext_act_in[58]));
    PIW \gen_piw_ext_act_in[59].PIW_ext_act_in_inst  (.PAD(ext_act_in[59]),
        .C(net_ext_act_in[59]));
    PIW \gen_piw_ext_act_in[60].PIW_ext_act_in_inst  (.PAD(ext_act_in[60]),
        .C(net_ext_act_in[60]));
    PIW \gen_piw_ext_act_in[61].PIW_ext_act_in_inst  (.PAD(ext_act_in[61]),
        .C(net_ext_act_in[61]));
    PIW \gen_piw_ext_act_in[62].PIW_ext_act_in_inst  (.PAD(ext_act_in[62]),
        .C(net_ext_act_in[62]));
    PIW \gen_piw_ext_act_in[63].PIW_ext_act_in_inst  (.PAD(ext_act_in[63]),
        .C(net_ext_act_in[63]));
    PIW \gen_piw_ext_act_in[64].PIW_ext_act_in_inst  (.PAD(ext_act_in[64]),
        .C(net_ext_act_in[64]));
    PIW \gen_piw_ext_act_in[65].PIW_ext_act_in_inst  (.PAD(ext_act_in[65]),
        .C(net_ext_act_in[65]));
    PIW \gen_piw_ext_act_in[66].PIW_ext_act_in_inst  (.PAD(ext_act_in[66]),
        .C(net_ext_act_in[66]));
    PIW \gen_piw_ext_act_in[67].PIW_ext_act_in_inst  (.PAD(ext_act_in[67]),
        .C(net_ext_act_in[67]));
    PIW \gen_piw_ext_act_in[68].PIW_ext_act_in_inst  (.PAD(ext_act_in[68]),
        .C(net_ext_act_in[68]));
    PIW \gen_piw_ext_act_in[69].PIW_ext_act_in_inst  (.PAD(ext_act_in[69]),
        .C(net_ext_act_in[69]));
    PIW \gen_piw_ext_act_in[70].PIW_ext_act_in_inst  (.PAD(ext_act_in[70]),
        .C(net_ext_act_in[70]));
    PIW \gen_piw_ext_act_in[71].PIW_ext_act_in_inst  (.PAD(ext_act_in[71]),
        .C(net_ext_act_in[71]));
    PIW \gen_piw_ext_act_in[72].PIW_ext_act_in_inst  (.PAD(ext_act_in[72]),
        .C(net_ext_act_in[72]));
    PIW \gen_piw_ext_act_in[73].PIW_ext_act_in_inst  (.PAD(ext_act_in[73]),
        .C(net_ext_act_in[73]));
    PIW \gen_piw_ext_act_in[74].PIW_ext_act_in_inst  (.PAD(ext_act_in[74]),
        .C(net_ext_act_in[74]));
    PIW \gen_piw_ext_act_in[75].PIW_ext_act_in_inst  (.PAD(ext_act_in[75]),
        .C(net_ext_act_in[75]));
    PIW \gen_piw_ext_act_in[76].PIW_ext_act_in_inst  (.PAD(ext_act_in[76]),
        .C(net_ext_act_in[76]));
    PIW \gen_piw_ext_act_in[77].PIW_ext_act_in_inst  (.PAD(ext_act_in[77]),
        .C(net_ext_act_in[77]));
    PIW \gen_piw_ext_act_in[78].PIW_ext_act_in_inst  (.PAD(ext_act_in[78]),
        .C(net_ext_act_in[78]));
    PIW \gen_piw_ext_act_in[79].PIW_ext_act_in_inst  (.PAD(ext_act_in[79]),
        .C(net_ext_act_in[79]));
    PIW \gen_piw_ext_act_in[80].PIW_ext_act_in_inst  (.PAD(ext_act_in[80]),
        .C(net_ext_act_in[80]));
    PIW \gen_piw_ext_act_in[81].PIW_ext_act_in_inst  (.PAD(ext_act_in[81]),
        .C(net_ext_act_in[81]));
    PIW \gen_piw_ext_act_in[82].PIW_ext_act_in_inst  (.PAD(ext_act_in[82]),
        .C(net_ext_act_in[82]));
    PIW \gen_piw_ext_act_in[83].PIW_ext_act_in_inst  (.PAD(ext_act_in[83]),
        .C(net_ext_act_in[83]));
    PIW \gen_piw_ext_act_in[84].PIW_ext_act_in_inst  (.PAD(ext_act_in[84]),
        .C(net_ext_act_in[84]));
    PIW \gen_piw_ext_act_in[85].PIW_ext_act_in_inst  (.PAD(ext_act_in[85]),
        .C(net_ext_act_in[85]));
    PIW \gen_piw_ext_act_in[86].PIW_ext_act_in_inst  (.PAD(ext_act_in[86]),
        .C(net_ext_act_in[86]));
    PIW \gen_piw_ext_act_in[87].PIW_ext_act_in_inst  (.PAD(ext_act_in[87]),
        .C(net_ext_act_in[87]));
    PIW \gen_piw_ext_act_in[88].PIW_ext_act_in_inst  (.PAD(ext_act_in[88]),
        .C(net_ext_act_in[88]));
    PIW \gen_piw_ext_act_in[89].PIW_ext_act_in_inst  (.PAD(ext_act_in[89]),
        .C(net_ext_act_in[89]));
    PIW \gen_piw_ext_act_in[90].PIW_ext_act_in_inst  (.PAD(ext_act_in[90]),
        .C(net_ext_act_in[90]));
    PIW \gen_piw_ext_act_in[91].PIW_ext_act_in_inst  (.PAD(ext_act_in[91]),
        .C(net_ext_act_in[91]));
    PIW \gen_piw_ext_act_in[92].PIW_ext_act_in_inst  (.PAD(ext_act_in[92]),
        .C(net_ext_act_in[92]));
    PIW \gen_piw_ext_act_in[93].PIW_ext_act_in_inst  (.PAD(ext_act_in[93]),
        .C(net_ext_act_in[93]));
    PIW \gen_piw_ext_act_in[94].PIW_ext_act_in_inst  (.PAD(ext_act_in[94]),
        .C(net_ext_act_in[94]));
    PIW \gen_piw_ext_act_in[95].PIW_ext_act_in_inst  (.PAD(ext_act_in[95]),
        .C(net_ext_act_in[95]));
    PIW \gen_piw_ext_act_in[96].PIW_ext_act_in_inst  (.PAD(ext_act_in[96]),
        .C(net_ext_act_in[96]));
    PIW \gen_piw_ext_act_in[97].PIW_ext_act_in_inst  (.PAD(ext_act_in[97]),
        .C(net_ext_act_in[97]));
    PIW \gen_piw_ext_act_in[98].PIW_ext_act_in_inst  (.PAD(ext_act_in[98]),
        .C(net_ext_act_in[98]));
    PIW \gen_piw_ext_act_in[99].PIW_ext_act_in_inst  (.PAD(ext_act_in[99]),
        .C(net_ext_act_in[99]));
    PIW \gen_piw_ext_act_in[100].PIW_ext_act_in_inst  (.PAD(ext_act_in[100]),
        .C(net_ext_act_in[100]));
    PIW \gen_piw_ext_act_in[101].PIW_ext_act_in_inst  (.PAD(ext_act_in[101]),
        .C(net_ext_act_in[101]));
    PIW \gen_piw_ext_act_in[102].PIW_ext_act_in_inst  (.PAD(ext_act_in[102]),
        .C(net_ext_act_in[102]));
    PIW \gen_piw_ext_act_in[103].PIW_ext_act_in_inst  (.PAD(ext_act_in[103]),
        .C(net_ext_act_in[103]));
    PIW \gen_piw_ext_act_in[104].PIW_ext_act_in_inst  (.PAD(ext_act_in[104]),
        .C(net_ext_act_in[104]));
    PIW \gen_piw_ext_act_in[105].PIW_ext_act_in_inst  (.PAD(ext_act_in[105]),
        .C(net_ext_act_in[105]));
    PIW \gen_piw_ext_act_in[106].PIW_ext_act_in_inst  (.PAD(ext_act_in[106]),
        .C(net_ext_act_in[106]));
    PIW \gen_piw_ext_act_in[107].PIW_ext_act_in_inst  (.PAD(ext_act_in[107]),
        .C(net_ext_act_in[107]));
    PIW \gen_piw_ext_act_in[108].PIW_ext_act_in_inst  (.PAD(ext_act_in[108]),
        .C(net_ext_act_in[108]));
    PIW \gen_piw_ext_act_in[109].PIW_ext_act_in_inst  (.PAD(ext_act_in[109]),
        .C(net_ext_act_in[109]));
    PIW \gen_piw_ext_act_in[110].PIW_ext_act_in_inst  (.PAD(ext_act_in[110]),
        .C(net_ext_act_in[110]));
    PIW \gen_piw_ext_act_in[111].PIW_ext_act_in_inst  (.PAD(ext_act_in[111]),
        .C(net_ext_act_in[111]));
    PIW \gen_piw_ext_act_in[112].PIW_ext_act_in_inst  (.PAD(ext_act_in[112]),
        .C(net_ext_act_in[112]));
    PIW \gen_piw_ext_act_in[113].PIW_ext_act_in_inst  (.PAD(ext_act_in[113]),
        .C(net_ext_act_in[113]));
    PIW \gen_piw_ext_act_in[114].PIW_ext_act_in_inst  (.PAD(ext_act_in[114]),
        .C(net_ext_act_in[114]));
    PIW \gen_piw_ext_act_in[115].PIW_ext_act_in_inst  (.PAD(ext_act_in[115]),
        .C(net_ext_act_in[115]));
    PIW \gen_piw_ext_act_in[116].PIW_ext_act_in_inst  (.PAD(ext_act_in[116]),
        .C(net_ext_act_in[116]));
    PIW \gen_piw_ext_act_in[117].PIW_ext_act_in_inst  (.PAD(ext_act_in[117]),
        .C(net_ext_act_in[117]));
    PIW \gen_piw_ext_act_in[118].PIW_ext_act_in_inst  (.PAD(ext_act_in[118]),
        .C(net_ext_act_in[118]));
    PIW \gen_piw_ext_act_in[119].PIW_ext_act_in_inst  (.PAD(ext_act_in[119]),
        .C(net_ext_act_in[119]));
    PIW \gen_piw_ext_act_in[120].PIW_ext_act_in_inst  (.PAD(ext_act_in[120]),
        .C(net_ext_act_in[120]));
    PIW \gen_piw_ext_act_in[121].PIW_ext_act_in_inst  (.PAD(ext_act_in[121]),
        .C(net_ext_act_in[121]));
    PIW \gen_piw_ext_act_in[122].PIW_ext_act_in_inst  (.PAD(ext_act_in[122]),
        .C(net_ext_act_in[122]));
    PIW \gen_piw_ext_act_in[123].PIW_ext_act_in_inst  (.PAD(ext_act_in[123]),
        .C(net_ext_act_in[123]));
    PIW \gen_piw_ext_act_in[124].PIW_ext_act_in_inst  (.PAD(ext_act_in[124]),
        .C(net_ext_act_in[124]));
    PIW \gen_piw_ext_act_in[125].PIW_ext_act_in_inst  (.PAD(ext_act_in[125]),
        .C(net_ext_act_in[125]));
    PIW \gen_piw_ext_act_in[126].PIW_ext_act_in_inst  (.PAD(ext_act_in[126]),
        .C(net_ext_act_in[126]));
    PIW \gen_piw_ext_act_in[127].PIW_ext_act_in_inst  (.PAD(ext_act_in[127]),
        .C(net_ext_act_in[127]));
    PIW \gen_piw_ext_act_in[128].PIW_ext_act_in_inst  (.PAD(ext_act_in[128]),
        .C(net_ext_act_in[128]));
    PIW \gen_piw_ext_act_in[129].PIW_ext_act_in_inst  (.PAD(ext_act_in[129]),
        .C(net_ext_act_in[129]));
    PIW \gen_piw_ext_act_in[130].PIW_ext_act_in_inst  (.PAD(ext_act_in[130]),
        .C(net_ext_act_in[130]));
    PIW \gen_piw_ext_act_in[131].PIW_ext_act_in_inst  (.PAD(ext_act_in[131]),
        .C(net_ext_act_in[131]));
    PIW \gen_piw_ext_act_in[132].PIW_ext_act_in_inst  (.PAD(ext_act_in[132]),
        .C(net_ext_act_in[132]));
    PIW \gen_piw_ext_act_in[133].PIW_ext_act_in_inst  (.PAD(ext_act_in[133]),
        .C(net_ext_act_in[133]));
    PIW \gen_piw_ext_act_in[134].PIW_ext_act_in_inst  (.PAD(ext_act_in[134]),
        .C(net_ext_act_in[134]));
    PIW \gen_piw_ext_act_in[135].PIW_ext_act_in_inst  (.PAD(ext_act_in[135]),
        .C(net_ext_act_in[135]));
    PIW \gen_piw_ext_act_in[136].PIW_ext_act_in_inst  (.PAD(ext_act_in[136]),
        .C(net_ext_act_in[136]));
    PIW \gen_piw_ext_act_in[137].PIW_ext_act_in_inst  (.PAD(ext_act_in[137]),
        .C(net_ext_act_in[137]));
    PIW \gen_piw_ext_act_in[138].PIW_ext_act_in_inst  (.PAD(ext_act_in[138]),
        .C(net_ext_act_in[138]));
    PIW \gen_piw_ext_act_in[139].PIW_ext_act_in_inst  (.PAD(ext_act_in[139]),
        .C(net_ext_act_in[139]));
    PIW \gen_piw_ext_act_in[140].PIW_ext_act_in_inst  (.PAD(ext_act_in[140]),
        .C(net_ext_act_in[140]));
    PIW \gen_piw_ext_act_in[141].PIW_ext_act_in_inst  (.PAD(ext_act_in[141]),
        .C(net_ext_act_in[141]));
    PIW \gen_piw_ext_act_in[142].PIW_ext_act_in_inst  (.PAD(ext_act_in[142]),
        .C(net_ext_act_in[142]));
    PIW \gen_piw_ext_act_in[143].PIW_ext_act_in_inst  (.PAD(ext_act_in[143]),
        .C(net_ext_act_in[143]));
    PIW \gen_piw_ext_act_in[144].PIW_ext_act_in_inst  (.PAD(ext_act_in[144]),
        .C(net_ext_act_in[144]));
    PIW \gen_piw_ext_act_in[145].PIW_ext_act_in_inst  (.PAD(ext_act_in[145]),
        .C(net_ext_act_in[145]));
    PIW \gen_piw_ext_act_in[146].PIW_ext_act_in_inst  (.PAD(ext_act_in[146]),
        .C(net_ext_act_in[146]));
    PIW \gen_piw_ext_act_in[147].PIW_ext_act_in_inst  (.PAD(ext_act_in[147]),
        .C(net_ext_act_in[147]));
    PIW \gen_piw_ext_act_in[148].PIW_ext_act_in_inst  (.PAD(ext_act_in[148]),
        .C(net_ext_act_in[148]));
    PIW \gen_piw_ext_act_in[149].PIW_ext_act_in_inst  (.PAD(ext_act_in[149]),
        .C(net_ext_act_in[149]));
    PIW \gen_piw_ext_act_in[150].PIW_ext_act_in_inst  (.PAD(ext_act_in[150]),
        .C(net_ext_act_in[150]));
    PIW \gen_piw_ext_act_in[151].PIW_ext_act_in_inst  (.PAD(ext_act_in[151]),
        .C(net_ext_act_in[151]));
    PIW \gen_piw_ext_act_in[152].PIW_ext_act_in_inst  (.PAD(ext_act_in[152]),
        .C(net_ext_act_in[152]));
    PIW \gen_piw_ext_act_in[153].PIW_ext_act_in_inst  (.PAD(ext_act_in[153]),
        .C(net_ext_act_in[153]));
    PIW \gen_piw_ext_act_in[154].PIW_ext_act_in_inst  (.PAD(ext_act_in[154]),
        .C(net_ext_act_in[154]));
    PIW \gen_piw_ext_act_in[155].PIW_ext_act_in_inst  (.PAD(ext_act_in[155]),
        .C(net_ext_act_in[155]));
    PIW \gen_piw_ext_act_in[156].PIW_ext_act_in_inst  (.PAD(ext_act_in[156]),
        .C(net_ext_act_in[156]));
    PIW \gen_piw_ext_act_in[157].PIW_ext_act_in_inst  (.PAD(ext_act_in[157]),
        .C(net_ext_act_in[157]));
    PIW \gen_piw_ext_act_in[158].PIW_ext_act_in_inst  (.PAD(ext_act_in[158]),
        .C(net_ext_act_in[158]));
    PIW \gen_piw_ext_act_in[159].PIW_ext_act_in_inst  (.PAD(ext_act_in[159]),
        .C(net_ext_act_in[159]));
    PIW \gen_piw_ext_act_in[160].PIW_ext_act_in_inst  (.PAD(ext_act_in[160]),
        .C(net_ext_act_in[160]));
    PIW \gen_piw_ext_act_in[161].PIW_ext_act_in_inst  (.PAD(ext_act_in[161]),
        .C(net_ext_act_in[161]));
    PIW \gen_piw_ext_act_in[162].PIW_ext_act_in_inst  (.PAD(ext_act_in[162]),
        .C(net_ext_act_in[162]));
    PIW \gen_piw_ext_act_in[163].PIW_ext_act_in_inst  (.PAD(ext_act_in[163]),
        .C(net_ext_act_in[163]));
    PIW \gen_piw_ext_act_in[164].PIW_ext_act_in_inst  (.PAD(ext_act_in[164]),
        .C(net_ext_act_in[164]));
    PIW \gen_piw_ext_act_in[165].PIW_ext_act_in_inst  (.PAD(ext_act_in[165]),
        .C(net_ext_act_in[165]));
    PIW \gen_piw_ext_act_in[166].PIW_ext_act_in_inst  (.PAD(ext_act_in[166]),
        .C(net_ext_act_in[166]));
    PIW \gen_piw_ext_act_in[167].PIW_ext_act_in_inst  (.PAD(ext_act_in[167]),
        .C(net_ext_act_in[167]));
    PIW \gen_piw_ext_act_in[168].PIW_ext_act_in_inst  (.PAD(ext_act_in[168]),
        .C(net_ext_act_in[168]));
    PIW \gen_piw_ext_act_in[169].PIW_ext_act_in_inst  (.PAD(ext_act_in[169]),
        .C(net_ext_act_in[169]));
    PIW \gen_piw_ext_act_in[170].PIW_ext_act_in_inst  (.PAD(ext_act_in[170]),
        .C(net_ext_act_in[170]));
    PIW \gen_piw_ext_act_in[171].PIW_ext_act_in_inst  (.PAD(ext_act_in[171]),
        .C(net_ext_act_in[171]));
    PIW \gen_piw_ext_act_in[172].PIW_ext_act_in_inst  (.PAD(ext_act_in[172]),
        .C(net_ext_act_in[172]));
    PIW \gen_piw_ext_act_in[173].PIW_ext_act_in_inst  (.PAD(ext_act_in[173]),
        .C(net_ext_act_in[173]));
    PIW \gen_piw_ext_act_in[174].PIW_ext_act_in_inst  (.PAD(ext_act_in[174]),
        .C(net_ext_act_in[174]));
    PIW \gen_piw_ext_act_in[175].PIW_ext_act_in_inst  (.PAD(ext_act_in[175]),
        .C(net_ext_act_in[175]));
    PIW \gen_piw_ext_act_in[176].PIW_ext_act_in_inst  (.PAD(ext_act_in[176]),
        .C(net_ext_act_in[176]));
    PIW \gen_piw_ext_act_in[177].PIW_ext_act_in_inst  (.PAD(ext_act_in[177]),
        .C(net_ext_act_in[177]));
    PIW \gen_piw_ext_act_in[178].PIW_ext_act_in_inst  (.PAD(ext_act_in[178]),
        .C(net_ext_act_in[178]));
    PIW \gen_piw_ext_act_in[179].PIW_ext_act_in_inst  (.PAD(ext_act_in[179]),
        .C(net_ext_act_in[179]));
    PIW \gen_piw_ext_act_in[180].PIW_ext_act_in_inst  (.PAD(ext_act_in[180]),
        .C(net_ext_act_in[180]));
    PIW \gen_piw_ext_act_in[181].PIW_ext_act_in_inst  (.PAD(ext_act_in[181]),
        .C(net_ext_act_in[181]));
    PIW \gen_piw_ext_act_in[182].PIW_ext_act_in_inst  (.PAD(ext_act_in[182]),
        .C(net_ext_act_in[182]));
    PIW \gen_piw_ext_act_in[183].PIW_ext_act_in_inst  (.PAD(ext_act_in[183]),
        .C(net_ext_act_in[183]));
    PIW \gen_piw_ext_act_in[184].PIW_ext_act_in_inst  (.PAD(ext_act_in[184]),
        .C(net_ext_act_in[184]));
    PIW \gen_piw_ext_act_in[185].PIW_ext_act_in_inst  (.PAD(ext_act_in[185]),
        .C(net_ext_act_in[185]));
    PIW \gen_piw_ext_act_in[186].PIW_ext_act_in_inst  (.PAD(ext_act_in[186]),
        .C(net_ext_act_in[186]));
    PIW \gen_piw_ext_act_in[187].PIW_ext_act_in_inst  (.PAD(ext_act_in[187]),
        .C(net_ext_act_in[187]));
    PIW \gen_piw_ext_act_in[188].PIW_ext_act_in_inst  (.PAD(ext_act_in[188]),
        .C(net_ext_act_in[188]));
    PIW \gen_piw_ext_act_in[189].PIW_ext_act_in_inst  (.PAD(ext_act_in[189]),
        .C(net_ext_act_in[189]));
    PIW \gen_piw_ext_act_in[190].PIW_ext_act_in_inst  (.PAD(ext_act_in[190]),
        .C(net_ext_act_in[190]));
    PIW \gen_piw_ext_act_in[191].PIW_ext_act_in_inst  (.PAD(ext_act_in[191]),
        .C(net_ext_act_in[191]));
    PIW \gen_piw_ext_act_in[192].PIW_ext_act_in_inst  (.PAD(ext_act_in[192]),
        .C(net_ext_act_in[192]));
    PIW \gen_piw_ext_act_in[193].PIW_ext_act_in_inst  (.PAD(ext_act_in[193]),
        .C(net_ext_act_in[193]));
    PIW \gen_piw_ext_act_in[194].PIW_ext_act_in_inst  (.PAD(ext_act_in[194]),
        .C(net_ext_act_in[194]));
    PIW \gen_piw_ext_act_in[195].PIW_ext_act_in_inst  (.PAD(ext_act_in[195]),
        .C(net_ext_act_in[195]));
    PIW \gen_piw_ext_act_in[196].PIW_ext_act_in_inst  (.PAD(ext_act_in[196]),
        .C(net_ext_act_in[196]));
    PIW \gen_piw_ext_act_in[197].PIW_ext_act_in_inst  (.PAD(ext_act_in[197]),
        .C(net_ext_act_in[197]));
    PIW \gen_piw_ext_act_in[198].PIW_ext_act_in_inst  (.PAD(ext_act_in[198]),
        .C(net_ext_act_in[198]));
    PIW \gen_piw_ext_act_in[199].PIW_ext_act_in_inst  (.PAD(ext_act_in[199]),
        .C(net_ext_act_in[199]));
    PIW \gen_piw_ext_act_in[200].PIW_ext_act_in_inst  (.PAD(ext_act_in[200]),
        .C(net_ext_act_in[200]));
    PIW \gen_piw_ext_act_in[201].PIW_ext_act_in_inst  (.PAD(ext_act_in[201]),
        .C(net_ext_act_in[201]));
    PIW \gen_piw_ext_act_in[202].PIW_ext_act_in_inst  (.PAD(ext_act_in[202]),
        .C(net_ext_act_in[202]));
    PIW \gen_piw_ext_act_in[203].PIW_ext_act_in_inst  (.PAD(ext_act_in[203]),
        .C(net_ext_act_in[203]));
    PIW \gen_piw_ext_act_in[204].PIW_ext_act_in_inst  (.PAD(ext_act_in[204]),
        .C(net_ext_act_in[204]));
    PIW \gen_piw_ext_act_in[205].PIW_ext_act_in_inst  (.PAD(ext_act_in[205]),
        .C(net_ext_act_in[205]));
    PIW \gen_piw_ext_act_in[206].PIW_ext_act_in_inst  (.PAD(ext_act_in[206]),
        .C(net_ext_act_in[206]));
    PIW \gen_piw_ext_act_in[207].PIW_ext_act_in_inst  (.PAD(ext_act_in[207]),
        .C(net_ext_act_in[207]));
    PIW \gen_piw_ext_act_in[208].PIW_ext_act_in_inst  (.PAD(ext_act_in[208]),
        .C(net_ext_act_in[208]));
    PIW \gen_piw_ext_act_in[209].PIW_ext_act_in_inst  (.PAD(ext_act_in[209]),
        .C(net_ext_act_in[209]));
    PIW \gen_piw_ext_act_in[210].PIW_ext_act_in_inst  (.PAD(ext_act_in[210]),
        .C(net_ext_act_in[210]));
    PIW \gen_piw_ext_act_in[211].PIW_ext_act_in_inst  (.PAD(ext_act_in[211]),
        .C(net_ext_act_in[211]));
    PIW \gen_piw_ext_act_in[212].PIW_ext_act_in_inst  (.PAD(ext_act_in[212]),
        .C(net_ext_act_in[212]));
    PIW \gen_piw_ext_act_in[213].PIW_ext_act_in_inst  (.PAD(ext_act_in[213]),
        .C(net_ext_act_in[213]));
    PIW \gen_piw_ext_act_in[214].PIW_ext_act_in_inst  (.PAD(ext_act_in[214]),
        .C(net_ext_act_in[214]));
    PIW \gen_piw_ext_act_in[215].PIW_ext_act_in_inst  (.PAD(ext_act_in[215]),
        .C(net_ext_act_in[215]));
    PIW \gen_piw_ext_act_in[216].PIW_ext_act_in_inst  (.PAD(ext_act_in[216]),
        .C(net_ext_act_in[216]));
    PIW \gen_piw_ext_act_in[217].PIW_ext_act_in_inst  (.PAD(ext_act_in[217]),
        .C(net_ext_act_in[217]));
    PIW \gen_piw_ext_act_in[218].PIW_ext_act_in_inst  (.PAD(ext_act_in[218]),
        .C(net_ext_act_in[218]));
    PIW \gen_piw_ext_act_in[219].PIW_ext_act_in_inst  (.PAD(ext_act_in[219]),
        .C(net_ext_act_in[219]));
    PIW \gen_piw_ext_act_in[220].PIW_ext_act_in_inst  (.PAD(ext_act_in[220]),
        .C(net_ext_act_in[220]));
    PIW \gen_piw_ext_act_in[221].PIW_ext_act_in_inst  (.PAD(ext_act_in[221]),
        .C(net_ext_act_in[221]));
    PIW \gen_piw_ext_act_in[222].PIW_ext_act_in_inst  (.PAD(ext_act_in[222]),
        .C(net_ext_act_in[222]));
    PIW \gen_piw_ext_act_in[223].PIW_ext_act_in_inst  (.PAD(ext_act_in[223]),
        .C(net_ext_act_in[223]));
    PIW \gen_piw_ext_act_in[224].PIW_ext_act_in_inst  (.PAD(ext_act_in[224]),
        .C(net_ext_act_in[224]));
    PIW \gen_piw_ext_act_in[225].PIW_ext_act_in_inst  (.PAD(ext_act_in[225]),
        .C(net_ext_act_in[225]));
    PIW \gen_piw_ext_act_in[226].PIW_ext_act_in_inst  (.PAD(ext_act_in[226]),
        .C(net_ext_act_in[226]));
    PIW \gen_piw_ext_act_in[227].PIW_ext_act_in_inst  (.PAD(ext_act_in[227]),
        .C(net_ext_act_in[227]));
    PIW \gen_piw_ext_act_in[228].PIW_ext_act_in_inst  (.PAD(ext_act_in[228]),
        .C(net_ext_act_in[228]));
    PIW \gen_piw_ext_act_in[229].PIW_ext_act_in_inst  (.PAD(ext_act_in[229]),
        .C(net_ext_act_in[229]));
    PIW \gen_piw_ext_act_in[230].PIW_ext_act_in_inst  (.PAD(ext_act_in[230]),
        .C(net_ext_act_in[230]));
    PIW \gen_piw_ext_act_in[231].PIW_ext_act_in_inst  (.PAD(ext_act_in[231]),
        .C(net_ext_act_in[231]));
    PIW \gen_piw_ext_act_in[232].PIW_ext_act_in_inst  (.PAD(ext_act_in[232]),
        .C(net_ext_act_in[232]));
    PIW \gen_piw_ext_act_in[233].PIW_ext_act_in_inst  (.PAD(ext_act_in[233]),
        .C(net_ext_act_in[233]));
    PIW \gen_piw_ext_act_in[234].PIW_ext_act_in_inst  (.PAD(ext_act_in[234]),
        .C(net_ext_act_in[234]));
    PIW \gen_piw_ext_act_in[235].PIW_ext_act_in_inst  (.PAD(ext_act_in[235]),
        .C(net_ext_act_in[235]));
    PIW \gen_piw_ext_act_in[236].PIW_ext_act_in_inst  (.PAD(ext_act_in[236]),
        .C(net_ext_act_in[236]));
    PIW \gen_piw_ext_act_in[237].PIW_ext_act_in_inst  (.PAD(ext_act_in[237]),
        .C(net_ext_act_in[237]));
    PIW \gen_piw_ext_act_in[238].PIW_ext_act_in_inst  (.PAD(ext_act_in[238]),
        .C(net_ext_act_in[238]));
    PIW \gen_piw_ext_act_in[239].PIW_ext_act_in_inst  (.PAD(ext_act_in[239]),
        .C(net_ext_act_in[239]));
    PIW \gen_piw_ext_act_in[240].PIW_ext_act_in_inst  (.PAD(ext_act_in[240]),
        .C(net_ext_act_in[240]));
    PIW \gen_piw_ext_act_in[241].PIW_ext_act_in_inst  (.PAD(ext_act_in[241]),
        .C(net_ext_act_in[241]));
    PIW \gen_piw_ext_act_in[242].PIW_ext_act_in_inst  (.PAD(ext_act_in[242]),
        .C(net_ext_act_in[242]));
    PIW \gen_piw_ext_act_in[243].PIW_ext_act_in_inst  (.PAD(ext_act_in[243]),
        .C(net_ext_act_in[243]));
    PIW \gen_piw_ext_act_in[244].PIW_ext_act_in_inst  (.PAD(ext_act_in[244]),
        .C(net_ext_act_in[244]));
    PIW \gen_piw_ext_act_in[245].PIW_ext_act_in_inst  (.PAD(ext_act_in[245]),
        .C(net_ext_act_in[245]));
    PIW \gen_piw_ext_act_in[246].PIW_ext_act_in_inst  (.PAD(ext_act_in[246]),
        .C(net_ext_act_in[246]));
    PIW \gen_piw_ext_act_in[247].PIW_ext_act_in_inst  (.PAD(ext_act_in[247]),
        .C(net_ext_act_in[247]));
    PIW \gen_piw_ext_act_in[248].PIW_ext_act_in_inst  (.PAD(ext_act_in[248]),
        .C(net_ext_act_in[248]));
    PIW \gen_piw_ext_act_in[249].PIW_ext_act_in_inst  (.PAD(ext_act_in[249]),
        .C(net_ext_act_in[249]));
    PIW \gen_piw_ext_act_in[250].PIW_ext_act_in_inst  (.PAD(ext_act_in[250]),
        .C(net_ext_act_in[250]));
    PIW \gen_piw_ext_act_in[251].PIW_ext_act_in_inst  (.PAD(ext_act_in[251]),
        .C(net_ext_act_in[251]));
    PIW \gen_piw_ext_act_in[252].PIW_ext_act_in_inst  (.PAD(ext_act_in[252]),
        .C(net_ext_act_in[252]));
    PIW \gen_piw_ext_act_in[253].PIW_ext_act_in_inst  (.PAD(ext_act_in[253]),
        .C(net_ext_act_in[253]));
    PIW \gen_piw_ext_act_in[254].PIW_ext_act_in_inst  (.PAD(ext_act_in[254]),
        .C(net_ext_act_in[254]));
    PIW \gen_piw_ext_act_in[255].PIW_ext_act_in_inst  (.PAD(ext_act_in[255]),
        .C(net_ext_act_in[255]));
    PO8W PO8W_done (.I(net_done), .PAD(done));
    PO8W PO8W_fc_valid (.I(net_fc_valid), .PAD(fc_valid));
    PO8W \gen_po8w_fc_result[0].PO8W_fc_result_inst  (.I(net_fc_result[0]),
        .PAD(fc_result[0]));
    PO8W \gen_po8w_fc_result[1].PO8W_fc_result_inst  (.I(net_fc_result[1]),
        .PAD(fc_result[1]));
    PO8W \gen_po8w_fc_result[2].PO8W_fc_result_inst  (.I(net_fc_result[2]),
        .PAD(fc_result[2]));
    PO8W \gen_po8w_fc_result[3].PO8W_fc_result_inst  (.I(net_fc_result[3]),
        .PAD(fc_result[3]));
    PO8W \gen_po8w_fc_result[4].PO8W_fc_result_inst  (.I(net_fc_result[4]),
        .PAD(fc_result[4]));
    PO8W \gen_po8w_fc_result[5].PO8W_fc_result_inst  (.I(net_fc_result[5]),
        .PAD(fc_result[5]));
    PO8W \gen_po8w_fc_result[6].PO8W_fc_result_inst  (.I(net_fc_result[6]),
        .PAD(fc_result[6]));
    PO8W \gen_po8w_fc_result[7].PO8W_fc_result_inst  (.I(net_fc_result[7]),
        .PAD(fc_result[7]));
    PO8W \gen_po8w_fc_result[8].PO8W_fc_result_inst  (.I(net_fc_result[8]),
        .PAD(fc_result[8]));
    PO8W \gen_po8w_fc_result[9].PO8W_fc_result_inst  (.I(net_fc_result[9]),
        .PAD(fc_result[9]));
    PO8W \gen_po8w_fc_result[10].PO8W_fc_result_inst  (.I(net_fc_result[10]),
        .PAD(fc_result[10]));
    PO8W \gen_po8w_fc_result[11].PO8W_fc_result_inst  (.I(net_fc_result[11]),
        .PAD(fc_result[11]));
    PO8W \gen_po8w_fc_result[12].PO8W_fc_result_inst  (.I(net_fc_result[12]),
        .PAD(fc_result[12]));
    PO8W \gen_po8w_fc_result[13].PO8W_fc_result_inst  (.I(net_fc_result[13]),
        .PAD(fc_result[13]));
    PO8W \gen_po8w_fc_result[14].PO8W_fc_result_inst  (.I(net_fc_result[14]),
        .PAD(fc_result[14]));
    PO8W \gen_po8w_fc_result[15].PO8W_fc_result_inst  (.I(net_fc_result[15]),
        .PAD(fc_result[15]));
    PO8W \gen_po8w_fc_result[16].PO8W_fc_result_inst  (.I(net_fc_result[16]),
        .PAD(fc_result[16]));
    PO8W \gen_po8w_fc_result[17].PO8W_fc_result_inst  (.I(net_fc_result[17]),
        .PAD(fc_result[17]));
    PO8W \gen_po8w_fc_result[18].PO8W_fc_result_inst  (.I(net_fc_result[18]),
        .PAD(fc_result[18]));
    PO8W \gen_po8w_fc_result[19].PO8W_fc_result_inst  (.I(net_fc_result[19]),
        .PAD(fc_result[19]));
    PO8W \gen_po8w_fc_result[20].PO8W_fc_result_inst  (.I(net_fc_result[20]),
        .PAD(fc_result[20]));
    PO8W \gen_po8w_fc_result[21].PO8W_fc_result_inst  (.I(net_fc_result[21]),
        .PAD(fc_result[21]));
    PO8W \gen_po8w_fc_result[22].PO8W_fc_result_inst  (.I(net_fc_result[22]),
        .PAD(fc_result[22]));
    PO8W \gen_po8w_fc_result[23].PO8W_fc_result_inst  (.I(net_fc_result[23]),
        .PAD(fc_result[23]));
    PO8W \gen_po8w_fc_result[24].PO8W_fc_result_inst  (.I(net_fc_result[24]),
        .PAD(fc_result[24]));
    PO8W \gen_po8w_fc_result[25].PO8W_fc_result_inst  (.I(net_fc_result[25]),
        .PAD(fc_result[25]));
    PO8W \gen_po8w_fc_result[26].PO8W_fc_result_inst  (.I(net_fc_result[26]),
        .PAD(fc_result[26]));
    PO8W \gen_po8w_fc_result[27].PO8W_fc_result_inst  (.I(net_fc_result[27]),
        .PAD(fc_result[27]));
    PO8W \gen_po8w_fc_result[28].PO8W_fc_result_inst  (.I(net_fc_result[28]),
        .PAD(fc_result[28]));
    PO8W \gen_po8w_fc_result[29].PO8W_fc_result_inst  (.I(net_fc_result[29]),
        .PAD(fc_result[29]));
    PO8W \gen_po8w_fc_result[30].PO8W_fc_result_inst  (.I(net_fc_result[30]),
        .PAD(fc_result[30]));
    PO8W \gen_po8w_fc_result[31].PO8W_fc_result_inst  (.I(net_fc_result[31]),
        .PAD(fc_result[31]));
    cnn_top inst_CNN_top ( .clk(net_clk), .rst_n(net_rst_n), .start(net_start),
         .ext_act_in({net_ext_act_in[255:0]}), .ext_act_valid(net_ext_act_valid),
         .done(net_done), .fc_result({net_fc_result[31:0]}), .fc_valid(net_fc_valid));

endmodule

