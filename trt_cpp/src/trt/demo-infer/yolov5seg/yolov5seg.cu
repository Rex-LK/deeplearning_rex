#include<infer/trt-infer.hpp>
#include<common/basic_tools.hpp>
#include<common/cuda-tools.hpp>
#include <common/trt-tensor.hpp>
#include <opencv2/opencv.hpp>
#include<demo-infer/yolov5seg/yolov5seg.h>

static const int CLASSES = 80;

using namespace std;
using namespace cv;

struct yolov5out_seg {
	int id;             
	float confidence;   
	Rect box;       
	Mat boxMask;
};

struct yolov5seg_bbox{
    float left, top, right, bottom, confidence;
    int class_label;
    vector<float> proto;
    Rect box;
    Mat boxMask; 
    yolov5seg_bbox() = default;

    yolov5seg_bbox(float left, float top, float right, float bottom, float confidence, int class_label,vector<float> proto,Rect box)
    :left(left), top(top), right(right), bottom(bottom), confidence(confidence), class_label(class_label),proto(proto),box(box){}
};

void DrawPred(Mat& img,std::vector<yolov5seg_bbox> result) {
	std::vector<Scalar> color;
	srand(time(0));
    for (int i = 0; i < CLASSES; i++)
    {
        int b = rand() % 256;
		int g = rand() % 256;
		int r = rand() % 256;
		color.push_back(Scalar(b, g, r));
    }
    Mat mask = img.clone();
    for (int i = 0; i < result.size(); i++) {
		int left, top;
		left = result[i].box.x;
		top = result[i].box.y;
		int color_num = i;
		rectangle(img, result[i].box,color[result[i].class_label], 2, 8);
        cv::Mat c = mask(result[i].box);

        cv::Mat a = result[i].boxMask;

        c.setTo(color[result[i].class_label], a);
        // imwrite(to_string(i) + "_.png", c);
        std::string label = std::to_string(result[i].class_label) + ":" + std::to_string(result[i].confidence);
        int baseLine;
		Size labelSize = getTextSize(label, FONT_HERSHEY_SIMPLEX, 0.5, 1, &baseLine);
		top = max(top, labelSize.height);
		putText(img, label, Point(left, top), FONT_HERSHEY_SIMPLEX, 1, color[result[i].class_label], 2);
	}
	addWeighted(img, 0.5, mask, 0.5, 0, img);

};



void Yolov5Seg::yolov5Seg_inference(){

    auto engine = TRT::load_infer("/home/rex/Desktop/tensorrt_learning/trt_cpp/workspace/yolov5s-seg.trtmodel");
    if(!engine){
        printf("load engine failed \n");
        return;
    }
    auto input       = engine->input();
    auto output      = engine->output();
    auto output1      = engine->output(1);

    int input_width  = input->width();
    int input_height = input->height();
    auto image = imread("/home/rex/Desktop/tensorrt_learning/trt_cpp/workspace/bus.jpg");
    auto img_o = image.clone();
    int img_w = image.cols;
    int img_h = image.rows;
    Mat input_image;
    resize(image,input_image,Size(640,640));
    Mat show_img = input_image.clone();

    input_image.convertTo(input_image, CV_32F);

    Mat channel_based[3];
    for(int i = 0; i < 3; ++i)
        channel_based[i] = Mat(input_height, input_width, CV_32F, input->cpu<float>(0, 2-i));

    split(input_image, channel_based);
    for(int i = 0; i < 3; ++i)
        channel_based[i] = (channel_based[i] / 255.0f);
    
    engine->forward(true);

    float *prob = output->cpu<float>();
    float *prob1 = output1->cpu<float>();

    float *predict = prob1;
    int cols = 117; // 85 + 32
    int len_proto = 32;
    int num_classes = 80 ;
    int rows = 25200;
    vector<yolov5seg_bbox> boxes;
    float confidence_threshold = 0.3;
    float nms_threshold = 0.5;

    for(int i = 0; i < rows; ++i){
        float* pitem = predict + i * cols;
        float objness = pitem[4];
        if(objness < confidence_threshold)
            continue;

        float* pclass = pitem + 5;
        int label     = std::max_element(pclass, pclass + num_classes) - pclass;

        float prob    = pclass[label];
        float confidence = prob * objness;
        if(confidence < confidence_threshold)
            continue;

        float cx     = pitem[0];
        float cy     = pitem[1];
        float width  = pitem[2];
        float height = pitem[3];


        // 通过反变换恢复到图像尺度
        float left   = (cx - width * 0.5);
        float top    = (cy - height * 0.5);
        float right  = (cx + width * 0.5);
        float bottom = (cy + height * 0.5);
        Rect rect(left,top,width,height);

        vector<float> temp_proto(pitem + 5 + num_classes, pitem + 5 + num_classes + len_proto);
        boxes.emplace_back(left, top, right, bottom, confidence, (float)label,temp_proto,rect);
        
    }
    std::sort(boxes.begin(), boxes.end(), [](yolov5seg_bbox &a, yolov5seg_bbox &b)
              { return a.confidence > b.confidence; });
    std::vector<bool> remove_flags(boxes.size());
    std::vector<yolov5seg_bbox> box_result;
    box_result.reserve(boxes.size());

    auto iou = [](const yolov5seg_bbox& a, const yolov5seg_bbox& b){
        float cross_left   = std::max(a.left, b.left);
        float cross_top    = std::max(a.top, b.top);
        float cross_right  = std::min(a.right, b.right);
        float cross_bottom = std::min(a.bottom, b.bottom);

        float cross_area = std::max(0.0f, cross_right - cross_left) * std::max(0.0f, cross_bottom - cross_top);
        float union_area = std::max(0.0f, a.right - a.left) * std::max(0.0f, a.bottom - a.top) 
                        + std::max(0.0f, b.right - b.left) * std::max(0.0f, b.bottom - b.top) - cross_area;
        if(cross_area == 0 || union_area == 0) return 0.0f;
        return cross_area / union_area;
    };

    for(int i = 0; i < boxes.size(); ++i){
        if(remove_flags[i]) continue;

        auto& ibox = boxes[i];
        box_result.emplace_back(ibox);
        for(int j = i + 1; j < boxes.size(); ++j){
            if(remove_flags[j]) continue;

            auto& jbox = boxes[j];
            if(ibox.class_label == jbox.class_label){
                // class matched
                if(iou(ibox, jbox) >= nms_threshold)
                    remove_flags[j] = true;
            }
        }
    }

    // for(auto& box : box_result){
    //     cv::rectangle(show_img, cv::Point(box.left, box.top), cv::Point(box.right, box.bottom), cv::Scalar(0, 255, 0), 2);
    //     cv::putText(show_img, cv::format("%.2f", box.confidence), cv::Point(box.left, box.top - 7), 0, 0.8, cv::Scalar(0, 0, 255), 2, 16);
    // }

    

    cv::imwrite("yolov5-pred.jpg", show_img);
    
    
    // // seg 
	Mat maskProposals;

    for(int i = 0;i<box_result.size();i++){
        vector<float> a = box_result[i].proto;
        maskProposals.push_back(Mat(a).t());
    }

    float* pdata = prob;
    int _segChannels = 32;
    int _segWidth = 160;
    int _segHeight = 160;
    int INPUT_H = 640;
    int INPUT_W = 640;
    int MASK_THRESHOLD = 0.5;
	vector<float> mask(pdata, pdata + _segChannels * _segWidth * _segHeight);

    Mat mask_protos = Mat(mask);
    // // reshape 成 32 * 160
    Mat protos = mask_protos.reshape(0, { _segChannels,_segWidth * _segHeight });
	std::cout<<protos.size<<std::endl;
    Mat matmulRes = (maskProposals * protos).t();
    Mat masks = matmulRes.reshape(box_result.size(), { _segWidth,_segHeight });
    std::vector<Mat> maskChannels;
    split(masks, maskChannels);
    for (int i = 0; i < box_result.size(); ++i) {
        Mat dest, mask;
        //sigmod
        cv::exp(-maskChannels[i], dest);
        // dist 160 * 160
        dest = 1.0 / (1.0 + dest);

        Rect roi(0,0,160,160);
		dest = dest(roi);
        resize(dest, mask, Size(640,640), INTER_NEAREST);
        Rect temp_rect = box_result[i].box;
        cv::Mat b;
        // mask = mask(temp_rect) > MASK_THRESHOLD;
        inRange(mask(temp_rect), 0.5, 1, b);
        // cv::imwrite(to_string(i) + "_.jpg", b);
        Point classIdPoint;
        double max_class_socre;
		minMaxLoc(b, 0, &max_class_socre, 0, &classIdPoint);
		max_class_socre = (float)max_class_socre;
		box_result[i].boxMask = b;
        cv::imwrite(to_string(i) + "_.jpg", b);
    }
    DrawPred(show_img, box_result);
    cv::imwrite("output-seg.jpg", show_img);
}