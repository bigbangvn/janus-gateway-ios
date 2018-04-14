//
//  HomeViewController.m
//  janus-gateway-ios
//
//  Created by Nguyen Trong Bang on 9/4/18.
//  Copyright © 2018 MineWave. All rights reserved.
//

#import "HomeViewController.h"
#import "ViewController.h"

@interface HomeViewController ()

@end

@implementation HomeViewController

- (void)viewDidLoad {
    [super viewDidLoad];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ViewController *vc = [ViewController new];
        [self.navigationController pushViewController:vc animated:YES];
    });
}

@end
