library(ggplot2)
library(Rcpp)
# library(cairo) for better fig in Linux
library(shiny)
options(stringsAsFactors = FALSE)

ui <- fluidPage(
  tags$h1("TCR Sequences",
          style = "font-family: 'Imgact'; color: #00008B;"),
  tags$hr(),
  selectInput("select_data", "Select data demo, user's data or raw TCR sequences",
              c("Data demo" = "d",
                "User's data" = "u",
                "TCR sequences" = "t")),
  fileInput("tcr_file","Upload the .csv file (format as: tcr,x,y,color)",
            multiple=FALSE,
            accept=c(".csv")
  ),
  downloadButton('download_example', 'Download example raw sequences'),
  downloadButton('download_result', 'Download analyzed results'),
  
  # Interactive plot
  tags$h4("Brush to zoom the target region"),
  fluidRow(
    column(
      width = 6,
      plotOutput(
        "plot_tcr",
        click = "plot_click",
        brush = brushOpts(id = "plot_brush",
                          resetOnNew = TRUE)
      ),
      verbatimTextOutput("info")
    ),
    column(
      width = 6,
      plotOutput(
        "plot_tcr_z",
        click = "plot_z_click"
      ),
      verbatimTextOutput("info_z")
    )
    
  )
)

server <- function(input, output) {
  sourceCpp(code = '
            #include <Rcpp.h>
            #include <iostream>
            #include <fstream>
            #include <sstream>
            #include <vector>
            #include <string>            
            using namespace Rcpp;

            int  BLOSUM62[128][128];     
            // [[Rcpp::export]]
            int loadBLOSUM62(){
                for (int i = 0; i < 128; ++i) {
                    for (int j = 0; j < 128; ++j) {
                       BLOSUM62[i][j] = 0;
                    }
                }
                std::ifstream file("blosum62.3col.txt");
                std::string   line;
            
                while(std::getline(file, line)){
                     std::stringstream   linestream(line);
                     std::string         a1;
                     std::string         a2;
                     int                 val;
                     std::getline(linestream, a1, \'\\t\');
                     std::getline(linestream, a2, \'\\t\');
                     linestream >> val;
                     BLOSUM62[(unsigned char) a1[0]][(unsigned char) a2[0]] = val;  
                }
                return 0;
              }
            
            // [[Rcpp::export]]
            int di(const std::string& v1, const std::string& v2){
              size_t len = v1.size();
              if (len > v2.size()) {
                  len = v2.size();
              }
              int d = 0;
              for (size_t i = 0 ; i != len; ++i) {
                  d += BLOSUM62[(unsigned char)v1[i]][(unsigned char)v2[i]];
              }
              return d;
            }
            // [[Rcpp::export]]
            NumericMatrix score(CharacterVector s, size_t len){
                loadBLOSUM62();
                std::vector<std::string> seq = Rcpp::as <std::vector<std::string> > (s);
                NumericMatrix smatrix(len, len);
                for (size_t i = 0; i < len; i++){
                    for (size_t j = 0; j <= i; j++){
                        smatrix(i, j) = di(seq[i], seq[j]);
                    }
                }
                return smatrix;
            }
            
            
            // [[Rcpp::export]]
            NumericMatrix loc_m(CharacterVector s, size_t len){
                std::vector<std::string> seq = Rcpp::as <std::vector<std::string> > (s);
                NumericMatrix dmatrix = score (s, len);
                for (size_t i = 0; i < len; i++){
                    for (size_t j = 0; j < i; j++){
                        dmatrix(i, j) = 1.0 - 2.0 * di(seq[i], seq[j]) / (dmatrix(i,i) + dmatrix(j, j));
                        dmatrix(j, i) = dmatrix(i, j);
                    }
                }
                for (size_t i = 0; i < len; i++){
                    dmatrix(i, i) = 0.0;
                }
                
                return dmatrix;
            }
            
            // [[Rcpp::export]]
            IntegerVector colv(CharacterVector s, size_t len){
              std::vector<std::string> seq = Rcpp::as <std::vector<std::string> > (s);
              NumericMatrix smatrix = score (s, len);
              const int THREAHOLD = 20;         
              int totalCluster = 1;  
              IntegerVector cluster(len, -1);
              cluster[0] = 1;
              int maxScore = -1000;
              int maxIdx = -1000;
              const int NUM_THREADS = 16;
            #ifdef _OPENMP
              omp_set_num_threads(NUM_THREADS);
            #endif
              int j;
              IntegerVector d(len);
              for (int i = 1; i < len; ++i){
                  maxScore = -1000;
            #pragma omp parallel for
                  for (j = 0; j <= i - 1; ++j){
                      if (smatrix(i,j) > maxScore){
                          maxScore = smatrix(i,j);
                          maxIdx = j;
                      }
                  }
                  if (maxScore > THREAHOLD){         
                      cluster[i] = cluster[maxIdx];
                  } else {
                    totalCluster ++;
                    cluster[i] = totalCluster;
                  }
                  
              }
              
              /*std::stringstream stream;
              std::vector<std::string> color(len);
              for (int k = 0; k < len; k++) {
                  stream << cluster[k];
                  // push_back??
                  stream >> color[k];
                  stream.clear();
              } */
              
               
              return cluster;
            }

  ')
  # Initilize ranges for axis
  ranges <- reactiveValues(rx = NULL, ry = NULL)
  ranges_z <- reactiveValues(rzx = NULL, rzy = NULL)
  # function to get first 500 rows of raw seq
  len.test <- function(raw_seq) {
    l <- length(raw_seq)
    if (l >500){
      print("Warning: > 500 rows detected! Only fist 500 rows will be analyzed.")
      return(head(raw_seq, 500))
    } else {
      return(raw_seq)
    }
  }
  # Read demo data/user data/TCR seq
  # Read the file as a data frame, 1st line as header, return empty data frame without input
  # Note: a .csv file with only seq column will be treated to generate entire file
  safe.read <- function(docu, slc) {
    if (slc == "d"){
      return(
        read.csv(
          "tcr.data.demo.csv",  # file under the same folder
          header = TRUE,
          sep = ",",
          stringsAsFactors = FALSE
        )
      )
    } else if (is.null(docu)) {
      empdata<-data.frame(tcr=c(NA),x=c(NA),y=c(NA),color=c(NA)) # color is required here
      return(empdata)
    } else if (slc == "u") {
      return(read.csv(
        docu$datapath,
        header = TRUE,
        sep = ",",
        stringsAsFactors = FALSE
      ))
    } else {
      results <- data.frame(tcr=c(NA),x=c(NA),y=c(NA),color=c(NA))
      tcr_seq <- read.csv(
        docu$datapath,
        header = TRUE,
        sep = ",",
        stringsAsFactors = FALSE
      )[, 1] # read a data frame with mere seq, get a char vector WITHOUT title
      # analyze with C++, get a matrix and then transfer to dataframe
      # Only first 500 rows are treated
      tcr_seq <- len.test(tcr_seq)
      slen <- length(tcr_seq) 
      dist_matrix <- loc_m(tcr_seq, slen)
      save(dist_matrix, file = "saved.dist_matrix.Rdata")
      # print(dist_matrix[1:5, 1:5])
      # print(tcr_seq)
      # print(slen)
      h <- diag(slen) - matrix(1, slen, 1) %*% matrix(1, 1, slen) / slen
      ret <- eigen(h %*% (-0.5 * dist_matrix) %*% h, symmetric = TRUE)
      x <- ret$vectors [, 1:2] %*% diag(ret$values[1:2])[,1]
      y <- ret$vectors [, 1:2] %*% diag(ret$values[1:2])[,2]
      color <- colv(tcr_seq, slen)
      save(color, file = "color.Rdata")
      # save(tcr_seq, file = "seq.Rdata")
      results <- as.data.frame(cbind(tcr_seq,x,y,color), stringsAsFactors = FALSE)
      # save(results, file = "matrix.Rdata")
      names(results) <- c("tcr","x","y","color")
      results$tcr <- as.character(results$tcr)
      results$x <- as.numeric(as.character(results$x))
      results$y <- as.numeric(as.character(results$y))
      results$color <- as.character(results$color)
      # save(results, file = "matrix.Rdata")
      return(results)
    }
  }
  
  # sort color with freq, and add freq to data
  color.dist <- function(frame) {
    # save(frame, file = "6.Rdata")
    sort_freq <- sort(table(frame$color), decreasing = T, na.last = NA)
    # avoid transfering to int with one cluster
    sort_freq <- as.table(sort_freq)
    save(sort_freq, file = "5.Rdata")
    # NA will be generated in table without color, which cannot be directly converted
    if (is.na(sort_freq[1])){
      sort_frame <- data.frame(color=c(NA),frequency=c(NA), plot_color=c("#ffffff"))
    } else {
      sort_frame <- as.data.frame(sort_freq, stringsAsFactors = FALSE)
      sort_frame$color <- rainbow(nrow(sort_frame))
    }
    names(sort_frame) <- c("color", "frequency", "plot_color")
    # save(sort_frame, file = "4.Rdata")
    # match and add freq after the original data
    r <- data.frame(tcr=frame$tcr, 
                    x=frame$x, 
                    y=frame$y, 
                    color=frame$color,
                    frequency=sort_frame$frequency[match(frame$color, sort_frame$color)],
                    plot_color=sort_frame$plot_color[match(frame$color, sort_frame$color)]
                    )
    names(r) <- c("tcr","x","y","color","frequency","plot_color")
    save(r, file = "3.Rdata")
    return(r)
  }
  
  
  # Zoom after brush
  observeEvent(input$plot_brush,{
    brush <- input$plot_brush
    if (!is.null(brush)) {
      ranges_z$rzx <- c(brush$xmin, brush$xmax)
      ranges_z$rzy <- c(brush$ymin, brush$ymax)
      # print(ranges_z$rzx)
      # print(ranges_z$rzy)
    } else {
      ranges_z$rzx <- NULL
      ranges_z$rzy <- NULL
    }
  })
  
  # Construct plot with zooming function
  # Left plot with entire data
  output$plot_tcr <- renderPlot({
    ggplot(
      color.dist(safe.read(input$tcr_file, input$select_data)),
      aes(x = x, y = y, color = color)) + 
      geom_point(aes(color=color)) +
      scale_color_manual(values = color.dist(safe.read(input$tcr_file, input$select_data))$plot_color) +
      coord_cartesian(xlim = ranges$rx, ylim = ranges$ry, expand = TRUE) +
      ggtitle("Entire data")
  })
  
  output$info <- renderPrint({
    nearPoints(safe.read(input$tcr_file, input$select_data),
               input$plot_click,
               xvar = "x",
               yvar = "y",
               addDist = TRUE
    )
  })
  # Right plot for zooming
  output$plot_tcr_z <- renderPlot({
    data <- color.dist(safe.read(input$tcr_file, input$select_data))
    color_table <- data[, c("color", "frequency", "plot_color")]
    color_table <- color_table[!duplicated(color_table),]
    color_table <- color_table[order(-color_table$frequency),]
    data$color <- factor(data$color, levels = color_table$color)  ## control the order of color in the figure legend
    color_table_mapping <- color_table$plot_color
    names(color_table_mapping) <- color_table$color
    ggplot(
      data,
      aes(x = x, y = y)) + 
      geom_point(aes(col=color)) +
      scale_color_manual(values = color_table_mapping) +
      # coord_cartesian(xlim = ranges_z$rzx, ylim = ranges_z$rzy, expand = TRUE) +
      ggtitle("Chosen region") 
  })
  output$info_z <- renderPrint({
    nearPoints(safe.read(input$tcr_file, input$select_data),
               input$plot_z_click,
               xvar = "x",
               yvar = "y",
               addDist = TRUE
    )
  })
  # Downloadable file for raw TCR seq, as an example
  output$download_example <- downloadHandler(
    filename = function() {
      paste("TCR_seq_example", "csv", sep = ".")
    },
    content = function(p) {
      file.copy("TCR_seq_example.csv", p)
    },
    contentType = "text/csv"
  )
  # Generate downloadable file with data frame generated by C++ or from input
  # Row names should be included in the data frame
  output$download_result <- downloadHandler(
    filename = function() {
      paste("TCR_analysis-", Sys.Date(), ".csv", sep = "")
    },
    content = function(file) {
      write.csv(safe.read(input$tcr_file, input$select_data), file, row.names=FALSE)
    },
    contentType = "text/csv"
  )
}

shinyApp(ui = ui, server = server)