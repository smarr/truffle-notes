#!/usr/bin/env Rscript
library(knitr);
args    <- commandArgs(trailingOnly = TRUE)
silence <- knit2html(
  args[1],
  header = "<link href='http://fonts.googleapis.com/css?family=Lora:400,400italic|Montserrat:400,700' rel='stylesheet' type='text/css'>
  <script type='text/javascript' src='http://stefan-marr.de/renaissance/code/shCore.js'></script>
  <script type='text/javascript' src='http://agorbatchev.typepad.com/pub/sh/3_0_83/scripts/shBrushJava.js'></script>
  <link type='text/css' rel='stylesheet' href='http://stefan-marr.de/renaissance/code/shCoreDefault.css'/>
  ",
  styleshee = '
    body {
       padding-top:  1em;
       max-width:   40em;
       margin:      auto;
    }
    p,li { 
        font-family: Lora,"Times New Roman",serif;
        font-weight: 400;
        font-size: 14pt;
        text-align: justify;
    }
    
    td {
        font-family: "Lucida Console", Monaco, monospace;
        font-weight: 300;
        font-size:80%
    }
    
    .center, .center { text-align: center; }
    .right,  .right  { text-align: right; }
    .left,   .left   { text-align: left; }
    
    h1, h2, h3, h4, h5 {
        font-family: Montserrat,Helvetica,Arial,sans-serif;
        font-weight: bold;
    }
    
    h1 code, h2 code, h3 code, h4 code, h5 code {
      font-size: 1.4em;
    }
    
    th {
        font-family: Montserrat,Helvetica,Arial,sans-serif;
        font-weight: 400;
    }
    
    img {
        margin: auto;
        display: block;
    }
    
    .sidenote {
        position: absolute;
        padding-left: 44em;
        width: 10em;
        font-size: 80%;
        text-align: left;
        display: block;
    }
    
    .half table { width: 50%; }
    .center table { margin: auto; }
    .full table { width: 100% }
    
    /* Header Numbering */
    body {counter-reset: h2}
      h2 {counter-reset: h3}
      h3 {counter-reset: h4}

      h2:before {counter-increment: h2; content: counter(h2) \". \\a0 \"}
      h3:before {counter-increment: h3; content: counter(h2) \".\" counter(h3) \" \\a0 \"}
      h4:before {counter-increment: h4; content: counter(h2) \".\" counter(h3) \".\" counter(h4) \" \\a0 \"}

      h2.nocount:before, h3.nocount:before, h4.nocount:before { content: \"\"; counter-increment: none }
    ');

